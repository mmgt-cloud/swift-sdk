import Foundation
import MMGTCore

/// A transaction reads its own writes. The callback must be synchronous and may throw to roll back.
public struct ReplicaTransaction: Sendable {
  var rows: [ReplicaRecordKey: ReplicaRecord]
  var intents: [ReplicaIntent] = []
  let collections: Set<String>
  let validate: @Sendable (ReplicaIntent) throws -> Void
  public func get(collection: String, id: String) -> ReplicaRecord? {
    guard let row = rows[.init(collection: collection, id: id)], !row.deleted else { return nil }
    return row
  }
  public func list(collection: String) -> [ReplicaRecord] {
    rows.values.filter { $0.key.collection == collection && !$0.deleted }.sorted {
      $0.key.id < $1.key.id
    }
  }
  public mutating func upsert(collection: String, id: String, data: JSONValue) throws {
    try put(.init(key: .init(collection: collection, id: id), data: data, deleted: false))
  }
  public mutating func delete(collection: String, id: String) throws {
    try put(.init(key: .init(collection: collection, id: id), data: nil, deleted: true))
  }
  private mutating func put(_ intent: ReplicaIntent) throws {
    guard collections.contains(intent.key.collection) else {
      throw ReplicaError.collectionNotSupported
    }
    try validateReplicaIntent(intent)
    try validate(intent)
    intents.removeAll { $0.key == intent.key }
    intents.append(intent)
    var row =
      rows[intent.key]
      ?? .init(
        key: intent.key, data: nil, deleted: true,
        serverVersion: nil, localRevision: nil, pending: true, issues: [])
    row.data = intent.data
    row.deleted = intent.deleted
    row.pending = true
    rows[intent.key] = row
  }
}

/// A local domain view. Construction and CRUD never call Auth, AI or Sync.
/// Keep one instance per active profile; close it before exposing a different profile to tools/UI.
public actor LocalReplica: ApplicationLifecycleParticipant {
  public nonisolated let identity: ReplicaIdentity
  public nonisolated let collections: [String]
  private nonisolated let lifetime = ReplicaLifetime()
  private let store: any ReplicaLocalStore
  private let validator: @Sendable (ReplicaIntent) throws -> Void
  private var client: SyncClient?
  private var generation = UUID()
  private var closed = false
  public init(
    identity: ReplicaIdentity, collections: [String], store: any ReplicaLocalStore,
    validate: @escaping @Sendable (ReplicaIntent) throws -> Void = { _ in }
  ) throws {
    let scope = try SyncScope(collections: collections)
    guard !scope.collections.isEmpty else { throw ReplicaError.collectionNotSupported }
    self.identity = identity
    self.collections = scope.collections
    self.store = store
    validator = validate
  }
  private func check(_ expected: UUID? = nil) throws {
    try Task.checkCancellation()
    guard !closed, expected == nil || expected == generation else { throw ReplicaError.closed }
  }
  public func snapshot() async throws -> ReplicaStoreSnapshot {
    try check()
    let expected = generation
    let result = try await store.replicaSnapshot(identity: identity)
    try check(expected)
    return result
  }
  public func get(collection: String, id: String) async throws -> ReplicaRecord? {
    try await snapshot().records.first {
      $0.key == .init(collection: collection, id: id) && !$0.deleted
    }
  }
  public func list(collection: String) async throws -> [ReplicaRecord] {
    try await snapshot().records.filter { $0.key.collection == collection && !$0.deleted }
  }
  public func transaction(_ body: @Sendable (inout ReplicaTransaction) throws -> Void) async throws
  {
    try check()
    let expected = generation
    let state = try await snapshot()
    guard state.metadata.adoptedImportID == nil else { throw ReplicaError.alreadyAdopted }
    var transaction = ReplicaTransaction(
      rows: Dictionary(uniqueKeysWithValues: state.records.map { ($0.key, $0) }),
      collections: Set(collections), validate: validator)
    try body(&transaction)
    try check(expected)
    guard !transaction.intents.isEmpty else { return }
    let intents = transaction.intents
    let store = store
    let identity = identity
    try await ReplicaLifetime.run([lifetime]) {
      try await store.commitReplica(
        identity: identity, expectedRevision: state.metadata.revision, intents: intents)
    }
    try check(expected)
  }
  public func upsert(collection: String, id: String, data: JSONValue) async throws {
    try await transaction { try $0.upsert(collection: collection, id: id, data: data) }
  }
  public func delete(collection: String, id: String) async throws {
    try await transaction { try $0.delete(collection: collection, id: id) }
  }
  /// Coalesced complete views. Polling observes other SQLite connections/processes too; no Web Locks
  /// or in-process-only notification assumption. Cancel observation when the application is inactive.
  public func changes() -> AsyncThrowingStream<ReplicaStoreSnapshot, any Error> {
    let expected = generation
    return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let task = Task {
        do {
          var revision: String?
          while !Task.isCancelled {
            try self.check(expected)
            let state = try await self.snapshot()
            if revision != state.metadata.revision {
              revision = state.metadata.revision
              continuation.yield(state)
            }
            try await Task.sleep(for: .milliseconds(200))
          }
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
  public func connect(
    tokenProvider: @escaping AccessTokenProvider,
    transport: any HTTPTransport = URLSessionTransport()
  ) async throws {
    try check()
    let expected = generation
    guard let account = identity.account else { throw ReplicaError.guestCannotSync }
    let state = try await snapshot()
    let candidate = try SyncClient(
      configuration: identity.configuration, userID: account.userID,
      tokenProvider: tokenProvider, store: store, clientID: state.metadata.deliveryClientID,
      transport: transport)
    do {
      try await confirm(candidate)
      try check(expected)
      if let old = client { await old.close() }
      try check(expected)
      client = candidate
    } catch {
      await candidate.close()
      throw error
    }
  }
  private func confirm(_ client: SyncClient) async throws {
    let bootstrap = try await client.bootstrap()
    guard bootstrap.appID == identity.configuration.appID, bootstrap.userID == identity.principal.id
    else {
      throw ReplicaError.identityMismatch
    }
    for name in collections {
      guard let collection = bootstrap.collections.first(where: { $0.key == name }),
        collection.enabled,
        collection.accessScope == "user", ["managed", "projected"].contains(collection.mode),
        collection.conflictPolicy == "reject_stale"
      else { throw ReplicaError.collectionNotSupported }
    }
  }
  public func synchronize(maxPages: Int = 100) async throws -> SyncRunResult {
    try check()
    let expected = generation
    guard let client else { throw MMGTError.unauthenticated }
    try await confirm(client)
    try check(expected)
    let result = try await client.sync(
      scope: SyncScope(collections: collections), maxPages: maxPages)
    try check(expected)
    return result
  }
  private func refreshForImport() async throws -> ReplicaStoreSnapshot {
    try check()
    let expected = generation
    guard let client else { throw MMGTError.unauthenticated }
    try await confirm(client)
    try check(expected)
    let result = try await client.refreshSnapshot(scope: SyncScope(collections: collections))
    guard !result.hasMore, !result.rebuilding else { throw ReplicaError.importChanged }
    try check(expected)
    return try await snapshot()
  }
  public func prepareImport(to target: LocalReplica) async throws -> ReplicaImportPlan {
    try check()
    let expected = generation
    guard identity.principal.isGuest, !target.identity.principal.isGuest,
      identity.configuration.storagePartition == target.identity.configuration.storagePartition
    else {
      throw ReplicaError.identityMismatch
    }
    guard await target.sameStore(store) else { throw ReplicaError.differentStore }
    let source = try await snapshot()
    if let id = source.metadata.adoptedImportID {
      let plan = try await store.replicaImport(id: id, source: identity)
      guard plan.target == target.identity else { throw ReplicaError.alreadyAdopted }
      return plan
    }
    let destination = try await target.refreshForImport()
    try check(expected)
    let live = source.records.filter { !$0.deleted }
    guard live.allSatisfy({ target.collections.contains($0.key.collection) }) else {
      throw ReplicaError.collectionNotSupported
    }
    let plan = ReplicaImportPlan(
      source: identity, target: target.identity,
      sourceRevision: source.metadata.revision, targetRevision: destination.metadata.revision,
      items: live.map { row in
        .init(source: row, target: destination.records.first { $0.key == row.key })
      },
      requiresConfirmation: destination.records.contains { !$0.deleted || $0.pending }
        || live.contains { row in destination.records.contains { $0.key == row.key } })
    return try await store.prepareReplicaImport(plan)
  }
  private func sameStore(_ other: any ReplicaLocalStore) -> Bool { store === other }
  private func validateImport(_ plan: ReplicaImportPlan, decisions: [ReplicaImportDecision]) throws
  {
    try check()
    guard plan.target == identity else { throw ReplicaError.identityMismatch }
    for item in plan.items {
      let decision = decisions.first { $0.key == item.source.key }
      if decision?.action == .keepTarget { continue }
      guard collections.contains(item.source.key.collection) else {
        throw ReplicaError.collectionNotSupported
      }
      let intent = ReplicaIntent(
        key: item.source.key, data: decision?.data ?? item.source.data, deleted: false)
      try validateReplicaIntent(intent)
      try validator(intent)
    }
  }
  public func approveImport(
    _ id: String, to target: LocalReplica, confirmed: Bool = false,
    decisions: [ReplicaImportDecision] = []
  ) async throws -> ReplicaImportPlan {
    try check()
    let expected = generation
    guard await target.sameStore(store) else { throw ReplicaError.differentStore }
    let plan = try await store.replicaImport(id: id, source: identity)
    guard plan.target == target.identity else { throw ReplicaError.identityMismatch }
    if plan.committed { return plan }
    try await target.validateImport(plan, decisions: decisions)
    try check(expected)
    let store = store
    let identity = identity
    let result = try await ReplicaLifetime.run([lifetime, target.lifetime]) {
      try await store.commitReplicaImport(
        id: id, source: identity, confirmed: confirmed, decisions: decisions)
    }
    try check(expected)
    return result
  }
  public func importProgress(_ id: String) async throws -> ReplicaImportProgress {
    try check()
    let plan = try await store.replicaImport(id: id, source: identity)
    let destination = try await store.replicaSnapshot(identity: plan.target)
    let ids = Set(plan.mutationIDs)
    let journal = destination.metadata.journal.filter { ids.contains($0.entry.mutation.mutationId) }
    return .init(
      plan: plan, pending: journal.filter { $0.state == "pending" }.count,
      applied: journal.filter { $0.state == "applied" }.count,
      resolved: journal.filter { $0.state == "resolved" }.count,
      issues: destination.issues.filter { ids.contains($0.entry.mutation.mutationId) })
  }
  /// nil chooses the confirmed server value; a replacement creates a new CAS mutation with a new ID.
  public func resolveIssue(_ mutationID: String, replacement: ReplicaIntent? = nil) async throws {
    try check()
    let expected = generation
    if let replacement {
      guard collections.contains(replacement.key.collection) else {
        throw ReplicaError.collectionNotSupported
      }
      try validateReplicaIntent(replacement)
      try validator(replacement)
    }
    let state = try await snapshot()
    try check(expected)
    let store = store
    let identity = identity
    try await ReplicaLifetime.run([lifetime]) {
      try await store.resolveReplicaIssue(
        identity: identity, expectedRevision: state.metadata.revision,
        mutationID: mutationID, replacement: replacement)
    }
    try check(expected)
  }
  public func close() async {
    closed = true
    lifetime.cancel(close: true)
    generation = UUID()
    let old = client
    client = nil
    await old?.close()
  }
  public func activityChanged(_ activity: ApplicationActivity) async {
    if case .signedOut = activity {
      await close()
    } else if case .background = activity {
      lifetime.cancel()
      generation = UUID()
      await client?.cancelPending()
    }
  }
}
