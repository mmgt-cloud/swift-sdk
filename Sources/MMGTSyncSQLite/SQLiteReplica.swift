import Foundation
import GRDB
import MMGTCore
import MMGTSync

extension SQLiteSyncStore {
  static func replicaKey(_ identity: ReplicaIdentity) throws -> String {
    if let account = identity.account { return try key(account) }
    // The discriminator and full canonical environment keep guests apart from existing accounts.
    return try key([
      "guest-replica-v1", identity.configuration.storagePartition, identity.principal.id,
    ])
  }
  static func metadata(_ db: Database, _ i: String) throws -> ReplicaMetadata? {
    try Data.fetchOne(
      db, sql: "SELECT payload FROM replica_metadata WHERE identity=?", arguments: [i]
    ).map(decode)
  }
  static func saveMetadata(_ db: Database, _ i: String, _ value: ReplicaMetadata) throws {
    try db.execute(
      sql:
        "INSERT INTO replica_metadata VALUES(?,?) ON CONFLICT(identity) DO UPDATE SET payload=excluded.payload",
      arguments: [i, try encoded(value)])
  }
  static func touchReplica(_ db: Database, _ i: String) throws {
    if var value = try metadata(db, i) {
      value.revision = try nextReplicaRevision(value.revision)
      try saveMetadata(db, i, value)
    }
  }
  static func state(_ db: Database, _ i: String, _ identity: ReplicaIdentity) throws
    -> ReplicaStoreSnapshot
  {
    let confirmed: [SyncRecord] = try Data.fetchAll(
      db, sql: "SELECT payload FROM records WHERE identity=? ORDER BY collection,record_id",
      arguments: [i]
    ).map(decode)
    let outbox: [OutboxEntry] = try Data.fetchAll(
      db, sql: "SELECT payload FROM outbox WHERE identity=? ORDER BY ordinal", arguments: [i]
    ).map(decode)
    let issues: [SyncIssue] = try Data.fetchAll(
      db, sql: "SELECT payload FROM issues WHERE identity=? ORDER BY mutation_id", arguments: [i]
    ).map(decode)
    var meta: ReplicaMetadata
    if let existing = try metadata(db, i) {
      guard existing.identity == identity else { throw ReplicaError.identityMismatch }
      meta = existing
    } else {
      meta = ReplicaMetadata(identity: identity)
      // v1/v2 already stored the real environment and account. Adopt original delivery identities
      // verbatim, including uncertain attempts and issues; no invented ownership or cursor reset.
      for entry in issues.map(\.entry) + outbox where (entry.mutation.workspaceId ?? "").isEmpty {
        if !meta.journal.contains(where: {
          $0.entry.mutation.mutationId == entry.mutation.mutationId
        }) {
          meta.journal.append(.init(entry: entry, localRevision: "0"))
        }
      }
      try saveMetadata(db, i, meta)
    }
    return .init(metadata: meta, confirmed: confirmed, outbox: outbox, issues: issues)
  }
  public func replicaSnapshot(identity: ReplicaIdentity) async throws -> ReplicaStoreSnapshot {
    let i = try Self.replicaKey(identity)
    if let existing = try await database.read({ db -> ReplicaStoreSnapshot? in
      guard try Self.metadata(db, i) != nil else { return nil }
      return try Self.state(db, i, identity)
    }) {
      return existing
    }
    return try await database.write { try Self.state($0, i, identity) }
  }
  static func appendIntent(
    _ db: Database, _ i: String, _ identity: ReplicaIdentity,
    _ intent: ReplicaIntent, meta: inout ReplicaMetadata,
    dependencies: [String] = []
  ) throws -> String {
    try validateReplicaIntent(intent)
    let previous = meta.journal.last { item in
      item.entry.mutation.collection == intent.key.collection
        && item.entry.mutation.recordId == intent.key.id && item.state != "resolved"
    }
    let record: SyncRecord? = try Data.fetchOne(
      db,
      sql: "SELECT payload FROM records WHERE identity=? AND collection=? AND record_id=?",
      arguments: [i, intent.key.collection, intent.key.id]
    ).map(decode)
    guard (record?.workspaceId ?? "").isEmpty else { throw ReplicaError.collision }
    meta.revision = try nextReplicaRevision(meta.revision)
    let entry = OutboxEntry(
      mutation: .init(
        collection: intent.key.collection, recordId: intent.key.id,
        op: intent.deleted ? "delete" : "upsert", data: intent.data, mutationId: UUID().uuidString,
        baseVersion: record?.version ?? "0"), deliveryClientID: meta.deliveryClientID)
    let predecessor = previous?.state == "pending" ? previous?.entry.mutation.mutationId : nil
    meta.journal.append(
      .init(
        entry: entry, localRevision: meta.revision,
        predecessor: predecessor, dependencies: dependencies))
    if !identity.principal.isGuest { try insertEntry(db, i, entry) }
    return entry.mutation.mutationId
  }
  public func commitReplica(
    identity: ReplicaIdentity, expectedRevision: String, intents: [ReplicaIntent]
  ) async throws {
    let i = try Self.replicaKey(identity)
    guard Set(intents.map(\.key)).count == intents.count else { throw ReplicaError.invalidRecord }
    for intent in intents { try validateReplicaIntent(intent) }
    try await database.write { db in
      try Task.checkCancellation()
      var meta = try Self.state(db, i, identity).metadata
      guard meta.revision == expectedRevision else { throw ReplicaError.staleRevision }
      guard meta.adoptedImportID == nil else { throw ReplicaError.alreadyAdopted }
      for intent in intents { _ = try Self.appendIntent(db, i, identity, intent, meta: &meta) }
      try Self.saveMetadata(db, i, meta)
    }
  }
  static func requireUnmanaged(_ db: Database, _ i: String, _ id: String) throws {
    if try metadata(db, i)?.journal.contains(where: { $0.entry.mutation.mutationId == id }) == true
    {
      throw ReplicaError.useReplicaResolution
    }
  }
  static func prepareReplicaEntry(_ db: Database, _ i: String, entry: inout OutboxEntry) throws
    -> Bool
  {
    guard let meta = try metadata(db, i),
      let item = meta.journal.first(where: {
        $0.entry.mutation.mutationId == entry.mutation.mutationId
      })
    else { return true }
    guard item.state == "pending" else { throw SyncStoreError.invalidSettlement }
    // An uncertain request must retain its exact wire contents across restarts and retries.
    if entry.attempted { return true }
    var waiting = false
    var blocked = false
    for id in item.dependencies + (item.predecessor.map { [$0] } ?? []) {
      if let previous = meta.journal.first(where: { $0.entry.mutation.mutationId == id }),
        previous.state == "applied", let version = previous.result?.version
      {
        if item.predecessor == id { entry.mutation.baseVersion = version }
      } else if let data = try Data.fetchOne(
        db, sql: "SELECT payload FROM outbox WHERE identity=? AND mutation_id=?",
        arguments: [i, id])
      {
        let previous: OutboxEntry = try decode(data)
        if previous.needsReconciliation { blocked = true } else { waiting = true }
      } else {
        blocked = true
      }
    }
    if blocked {
      entry.needsReconciliation = true
      try db.execute(
        sql: "UPDATE outbox SET payload=? WHERE identity=? AND mutation_id=?",
        arguments: [try encoded(entry), i, entry.mutation.mutationId])
      return false
    }
    return !waiting
  }
  static func settleReplicaEntry(
    _ db: Database, _ i: String, entry: OutboxEntry, result: SyncPushResult
  ) throws {
    guard var meta = try metadata(db, i),
      let index = meta.journal.firstIndex(where: {
        $0.entry.mutation.mutationId == result.mutationId
      })
    else { return }
    if result.status == "applied", let version = result.version {
      let m = entry.mutation
      let change = SyncChange(
        sequence: version, collection: m.collection, recordId: m.recordId,
        op: m.op, version: version, data: m.data, workspaceId: m.workspaceId,
        userId: meta.identity.principal.id, createdAt: Date().ISO8601Format())
      try saveRecord(db, i, change, floors: floors(db, i))
      meta.journal[index].state = "applied"
    }
    meta.journal[index].result = result
    meta.revision = try nextReplicaRevision(meta.revision)
    try saveMetadata(db, i, meta)
  }
  public func resolveReplicaIssue(
    identity: ReplicaIdentity, expectedRevision: String, mutationID: String,
    replacement: ReplicaIntent?
  ) async throws {
    let i = try Self.replicaKey(identity)
    try await database.write { db in
      let state = try Self.state(db, i, identity)
      var meta = state.metadata
      guard meta.revision == expectedRevision else { throw ReplicaError.staleRevision }
      guard meta.adoptedImportID == nil else { throw ReplicaError.alreadyAdopted }
      guard let issue = state.issues.first(where: { $0.entry.mutation.mutationId == mutationID })
      else {
        throw ReplicaError.reconciliationRequired
      }
      let key = ReplicaRecordKey(
        collection: issue.entry.mutation.collection, id: issue.entry.mutation.recordId)
      if let replacement, replacement.key != key { throw ReplicaError.invalidRecord }
      func matches(_ entry: OutboxEntry) -> Bool {
        entry.mutation.collection == key.collection && entry.mutation.recordId == key.id
      }
      guard !state.outbox.contains(where: { matches($0) && $0.attempted }) else {
        throw SyncStoreError.mutationAlreadyAttempted
      }
      // Resolve the record's whole pending chain, preserving every journal ID as resolved.
      // A replacement starts a fresh CAS from the confirmed snapshot, never from a failed ancestor.
      for entry in state.outbox.filter(matches) + state.issues.map(\.entry).filter(matches) {
        try db.execute(
          sql: "DELETE FROM issues WHERE identity=? AND mutation_id=?",
          arguments: [i, entry.mutation.mutationId])
        try db.execute(
          sql: "DELETE FROM outbox WHERE identity=? AND mutation_id=?",
          arguments: [i, entry.mutation.mutationId])
      }
      for index in meta.journal.indices
      where matches(meta.journal[index].entry) && meta.journal[index].state == "pending" {
        meta.journal[index].state = "resolved"
      }
      if let replacement { _ = try Self.appendIntent(db, i, identity, replacement, meta: &meta) }
      meta.revision = try nextReplicaRevision(meta.revision)
      try Self.saveMetadata(db, i, meta)
    }
  }
  static func importPlan(_ db: Database, _ id: String, _ source: String) throws -> ReplicaImportPlan
  {
    guard
      let data = try Data.fetchOne(
        db, sql: "SELECT payload FROM replica_imports WHERE id=? AND source=?",
        arguments: [id, source])
    else {
      throw ReplicaError.importChanged
    }
    return try decode(data)
  }
  public func replicaImport(id: String, source: ReplicaIdentity) async throws -> ReplicaImportPlan {
    let i = try Self.replicaKey(source)
    return try await database.read { try Self.importPlan($0, id, i) }
  }
  public func prepareReplicaImport(_ plan: ReplicaImportPlan) async throws -> ReplicaImportPlan {
    let source = try Self.replicaKey(plan.source)
    let target = try Self.replicaKey(plan.target)
    guard plan.source.principal.isGuest, !plan.target.principal.isGuest,
      plan.source.configuration.storagePartition == plan.target.configuration.storagePartition
    else { throw ReplicaError.identityMismatch }
    return try await database.write { db in
      let a = try Self.state(db, source, plan.source)
      let b = try Self.state(db, target, plan.target)
      guard a.metadata.adoptedImportID == nil else { throw ReplicaError.alreadyAdopted }
      guard a.metadata.revision == plan.sourceRevision, b.metadata.revision == plan.targetRevision
      else { throw ReplicaError.importChanged }
      // Derive items from durable state, not caller-supplied previews.
      let records = a.records.filter { !$0.deleted }
      let items = records.map { row in
        ReplicaImportItem(source: row, target: b.records.first { $0.key == row.key })
      }
      let required =
        b.records.contains { !$0.deleted || $0.pending } || items.contains { $0.target != nil }
      let authoritative = ReplicaImportPlan(
        id: plan.id, source: plan.source, target: plan.target,
        sourceRevision: plan.sourceRevision, targetRevision: plan.targetRevision, items: items,
        requiresConfirmation: required)
      try db.execute(
        sql: "INSERT INTO replica_imports VALUES(?,?,?)",
        arguments: [plan.id, source, try Self.encoded(authoritative)])
      return authoritative
    }
  }
  public func commitReplicaImport(
    id: String, source: ReplicaIdentity, confirmed: Bool,
    decisions: [ReplicaImportDecision]
  ) async throws -> ReplicaImportPlan {
    let a = try Self.replicaKey(source)
    return try await database.write { db in
      var plan = try Self.importPlan(db, id, a)
      if plan.committed { return plan }
      let b = try Self.replicaKey(plan.target)
      var sourceState = try Self.state(db, a, source)
      var targetState = try Self.state(db, b, plan.target)
      guard sourceState.metadata.adoptedImportID == nil else { throw ReplicaError.alreadyAdopted }
      guard sourceState.metadata.revision == plan.sourceRevision,
        targetState.metadata.revision == plan.targetRevision
      else { throw ReplicaError.importChanged }
      guard !plan.requiresConfirmation || confirmed else { throw ReplicaError.confirmationRequired }
      guard Set(decisions.map(\.key)).count == decisions.count,
        decisions.allSatisfy({ d in plan.items.contains { $0.source.key == d.key } })
      else { throw ReplicaError.invalidRecord }
      var selected: [(ReplicaImportItem, ReplicaImportDecision)] = []
      for item in plan.items {
        let decision =
          decisions.first { $0.key == item.source.key }
          ?? .init(key: item.source.key, action: .importRecord)
        if decision.action == .keepTarget { continue }
        if let existing = item.target {
          guard decision.action == .replaceTarget, !existing.pending, existing.issues.isEmpty else {
            throw ReplicaError.collision
          }
        }
        try validateReplicaIntent(
          .init(key: item.source.key, data: decision.data ?? item.source.data, deleted: false))
        selected.append((item, decision))
      }
      let selectedKeys = Set(selected.map { $0.0.source.key })
      var written: [ReplicaRecordKey: String] = [:]
      while !selected.isEmpty {
        var progressed = false
        for (item, decision) in selected {
          var wait = false
          var dependencies: [String] = []
          for key in decision.dependencies {
            if let id = written[key] {
              dependencies.append(id)
            } else if selectedKeys.contains(key) {
              wait = true
            } else if !targetState.records.contains(where: {
              $0.key == key && !$0.deleted && !$0.pending && $0.issues.isEmpty
            }) {
              throw ReplicaError.unresolvedDependency
            }
          }
          if wait { continue }
          let mutationID = try Self.appendIntent(
            db, b, plan.target,
            .init(key: item.source.key, data: decision.data ?? item.source.data, deleted: false),
            meta: &targetState.metadata, dependencies: dependencies)
          written[item.source.key] = mutationID
          plan.mutationIDs.append(mutationID)
          selected.removeAll { $0.0.source.key == item.source.key }
          progressed = true
        }
        guard progressed else { throw ReplicaError.dependencyCycle }
      }
      plan.committed = true
      sourceState.metadata.adoptedImportID = id
      sourceState.metadata.revision = try nextReplicaRevision(sourceState.metadata.revision)
      // Includes an empty import: the guest copy is retained and bound to exactly this target.
      targetState.metadata.revision = try nextReplicaRevision(targetState.metadata.revision)
      try Self.saveMetadata(db, a, sourceState.metadata)
      try Self.saveMetadata(db, b, targetState.metadata)
      try db.execute(
        sql: "UPDATE replica_imports SET payload=? WHERE id=? AND source=?",
        arguments: [try Self.encoded(plan), id, a])
      return plan
    }
  }
}
