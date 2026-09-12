import Foundation
import MMGTCore

public actor SyncClient: ApplicationLifecycleParticipant {
  public static let contractRevision = "2026-09-05"
  public nonisolated let identity: AccountIdentity
  public nonisolated let clientID: String
  private let http: HTTPClient
  private let store: (any SyncLocalStore)?
  private let grantProvider: SyncGrantProvider?
  private var generation = UUID()
  private var closed = false
  private var requests: [UUID: Task<Data, any Error>] = [:]
  private var runTask: (id: UUID, task: Task<SyncRunResult, any Error>)?

  public init(
    configuration: ServiceConfiguration, userID: String,
    tokenProvider: @escaping AccessTokenProvider,
    grantProvider: SyncGrantProvider? = nil, store: (any SyncLocalStore)? = nil,
    clientID: String = UUID().uuidString, transport: any HTTPTransport = URLSessionTransport()
  ) throws {
    guard !clientID.isEmpty else { throw MMGTError.invalidConfiguration("A client ID is required") }
    identity = try AccountIdentity(configuration: configuration, userID: userID)
    self.clientID = clientID
    self.store = store
    self.grantProvider = grantProvider
    http = HTTPClient(
      configuration: configuration, tokenProvider: tokenProvider, transport: transport)
  }
  private func check(_ expected: UUID? = nil) throws {
    try Task.checkCancellation()
    guard !closed, expected == nil || expected == generation else { throw MMGTError.sessionChanged }
  }
  public func close() {
    closed = true
    cancelPending()
  }
  public func cancelPending() {
    generation = UUID()
    runTask?.task.cancel()
    runTask = nil
    for task in requests.values { task.cancel() }
    requests.removeAll()
  }
  public func activityChanged(_ activity: ApplicationActivity) {
    if case .signedOut = activity {
      close()
    } else if case .background = activity {
      cancelPending()
    }
  }
  private func localStore() throws -> any SyncLocalStore {
    guard let store else {
      throw MMGTError.invalidConfiguration("This operation requires a SyncLocalStore")
    }
    return store
  }
  private func request<T: Decodable & Sendable>(
    _ path: String, method: String = "POST", body: JSONValue? = nil, scope: SyncScope
  ) async throws -> T {
    try check()
    let expected = generation
    let id = UUID()
    let http = http
    let grantProvider = grantProvider
    let task = Task {
      var headers: [String: String] = ["X-Sync-User-ID": self.identity.userID]
      if !scope.workspaceIDs.isEmpty {
        guard let grant = try await grantProvider?(scope), !grant.isEmpty else {
          throw MMGTError.unauthenticated
        }
        headers["X-Sync-Grant"] = grant
      }
      try Task.checkCancellation()
      return try await http.send(
        path: ["app", http.configuration.appID, path], method: method,
        data: body.map { try JSONEncoder().encode($0) }, headers: headers)
    }
    requests[id] = task
    defer { requests[id] = nil }
    let data = try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
    try check(expected)
    return try JSONDecoder().decode(T.self, from: data)
  }
  /// Scope selects the workspace grant. The response is metadata for all user
  /// collections and workspace collections visible to that grant, not a feed page.
  public func bootstrap(scope: SyncScope = try! SyncScope()) async throws -> SyncBootstrapResponse {
    let response: SyncBootstrapResponse = try await request(
      "bootstrap", method: "GET", scope: scope)
    guard response.contractRevision == Self.contractRevision else {
      throw MMGTError.unsupported("Sync contract \(response.contractRevision)")
    }
    return response
  }
  public func push(_ input: SyncPushRequest) async throws -> SyncPushResponse {
    let scope = try SyncScope(
      collections: input.mutations.map(\.collection),
      workspaceIDs: input.mutations.compactMap(\.workspaceId))
    let response: SyncPushResponse = try await request("push", body: .encoding(input), scope: scope)
    guard Set(response.results.map(\.mutationId)).count == response.results.count else {
      throw SyncStoreError.invalidSettlement
    }
    for result in response.results {
      guard let sent = input.mutations.first(where: { $0.mutationId == result.mutationId }),
        sent.collection == result.collection, sent.recordId == result.recordId,
        ["applied", "conflict", "rejected"].contains(result.status)
      else { throw SyncStoreError.invalidSettlement }
      if let version = result.version { try SyncVersions.validate(version) }
      if result.status == "applied", result.version == nil {
        throw SyncStoreError.invalidSettlement
      }
      if result.status == "conflict", (result.conflictId ?? "").isEmpty {
        throw SyncStoreError.invalidSettlement
      }
    }
    return response
  }
  public func pull(_ input: SyncPullRequest = .init()) async throws -> SyncPullResponse {
    var input = input
    if input.clientId == nil { input.clientId = clientID }
    let scope = try SyncScope(
      collections: input.collections ?? [], workspaceIDs: input.workspaceIds ?? [])
    let response: SyncPullResponse = try await request("pull", body: .encoding(input), scope: scope)
    guard !response.nextCursor.isEmpty else { throw SyncStoreError.invalidChange }
    for change in response.changes {
      try validateSyncChange(change, identity: identity, scope: scope)
    }
    return response
  }
  public func snapshot(_ input: SyncSnapshotRequest = .init()) async throws -> SyncSnapshotResponse
  {
    let scope = try SyncScope(
      collections: input.collections ?? [], workspaceIDs: input.workspaceIds ?? [])
    let response: SyncSnapshotResponse = try await request(
      "snapshot", body: .encoding(input), scope: scope)
    try SyncVersions.validate(response.watermark)
    guard response.hasMore ? !(response.nextPage ?? "").isEmpty : !(response.cursor ?? "").isEmpty
    else { throw SyncStoreError.invalidChange }
    for change in response.records {
      try validateSyncChange(change, identity: identity, scope: scope)
    }
    return response
  }
  private func local(_ mutation: SyncMutation, newID: Bool = false) throws -> OutboxEntry {
    if let version = mutation.baseVersion { try SyncVersions.validate(version) }
    let payload = SyncMutationPayload(
      collection: mutation.collection, recordId: mutation.recordId, op: mutation.op,
      data: mutation.data,
      mutationId: newID ? UUID().uuidString : mutation.mutationId ?? UUID().uuidString,
      baseVersion: mutation.baseVersion, workspaceId: mutation.workspaceId)
    guard try JSONEncoder().encode(payload).count < 900_000 else {
      throw MMGTError.invalidConfiguration("Sync mutation exceeds 900 KB")
    }
    return .init(mutation: payload, deliveryClientID: clientID)
  }
  @discardableResult public func write(_ mutation: SyncMutation) async throws -> OutboxEntry {
    try await writeBatch([mutation])[0]
  }
  @discardableResult public func writeBatch(_ mutations: [SyncMutation]) async throws
    -> [OutboxEntry]
  {
    try check()
    let entries = try mutations.map { try local($0) }
    try await localStore().addOutbox(identity: identity, entries: entries)
    return entries
  }
  public func replaceLocalMutation(_ mutation: SyncMutation) async throws {
    try check()
    try await localStore().replaceRecordMutation(identity: identity, entry: local(mutation))
  }
  public func listLocalRecords(collection: String) async throws -> [SyncRecord] {
    try await localStore().records(identity: identity, collection: collection)
  }
  public func getLocalRecord(collection: String, id: String) async throws -> SyncRecord? {
    try await localStore().record(identity: identity, collection: collection, id: id)
  }
  public func listLocalOutbox() async throws -> [OutboxEntry] {
    try await localStore().outbox(identity: identity)
  }
  public func removeLocalOutbox(_ ids: [String]) async throws {
    try await localStore().removeOutbox(identity: identity, mutationIDs: ids)
  }
  public func listLocalConflicts() async throws -> [SyncIssue] {
    try await localStore().issues(identity: identity)
  }
  public func clearLocalConflicts(_ ids: [String]) async throws {
    try await localStore().removeIssues(identity: identity, mutationIDs: ids)
  }
  public func resolveLocalConflict(_ id: String, replacement: SyncMutation) async throws {
    try check()
    try await localStore().resolveIssue(
      identity: identity, mutationID: id, replacement: local(replacement, newID: true))
  }
  public func rebuild(scope: SyncScope = try! SyncScope(), maxPages: Int = 100, limit: Int = 500)
    async throws -> SyncRunResult
  {
    try check()
    let store = try localStore()
    let state = try await store.feed(identity: identity, scope: scope)
    guard
      try await store.resetFeed(
        identity: identity, scope: scope, expectedRevision: state.revision, reconcile: true)
    else { throw SyncStoreError.staleFeed }
    return try await sync(scope: scope, maxPages: maxPages, limit: limit)
  }
  /// A fresh authoritative view for import planning, preserving pending delivery and issues.
  public func refreshSnapshot(
    scope: SyncScope = try! SyncScope(), maxPages: Int = 100, limit: Int = 500
  )
    async throws -> SyncRunResult
  {
    try check()
    let store = try localStore()
    let state = try await store.feed(identity: identity, scope: scope)
    guard
      try await store.resetFeed(
        identity: identity, scope: scope,
        expectedRevision: state.revision, reconcile: false)
    else { throw SyncStoreError.staleFeed }
    return try await sync(scope: scope, maxPages: maxPages, limit: limit, pullOnly: true)
  }
  public func sync(
    scope: SyncScope = try! SyncScope(), maxPages: Int = 100, limit: Int = 500,
    pullOnly: Bool = false
  )
    async throws -> SyncRunResult
  {
    try check()
    guard (1...10_000).contains(maxPages), (1...1_000).contains(limit) else {
      throw MMGTError.invalidConfiguration("Invalid Sync page bounds")
    }
    guard runTask == nil else { throw SyncStoreError.staleFeed }
    let id = UUID()
    let expected = generation
    let task = Task {
      try await self.run(
        scope: scope, maxPages: maxPages, limit: limit, expected: expected, pullOnly: pullOnly)
    }
    runTask = (id, task)
    defer { if runTask?.id == id { runTask = nil } }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
  private func drain(
    scope: SyncScope, maxPages: Int, limit: Int, expected: UUID, pages: inout Int,
    result: inout SyncRunResult
  ) async throws -> Bool {
    let store = try localStore()
    var attempts = 0
    while pages < maxPages && attempts < maxPages * 3 {
      attempts += 1
      try check(expected)
      let state = try await store.feed(identity: identity, scope: scope)
      result.cursor = state.cursor
      result.rebuilding = state.cursor == nil
      do {
        if let cursor = state.cursor {
          let page = try await pull(
            .init(
              cursor: cursor, limit: limit, collections: scope.collections,
              workspaceIds: scope.workspaceIDs))
          pages += 1
          try check(expected)
          guard
            try await store.commitPage(
              identity: identity, scope: scope, expectedRevision: state.revision, page: page)
          else { continue }
          result.pulled += page.changes.count
          result.cursor = page.nextCursor
          if !page.hasMore { return true }
        } else {
          let page = try await snapshot(
            .init(
              collections: scope.collections, workspaceIds: scope.workspaceIDs,
              pageToken: state.snapshot?.nextPage, limit: limit))
          pages += 1
          try check(expected)
          guard
            try await store.commitSnapshotPage(
              identity: identity, scope: scope, expectedRevision: state.revision, page: page)
          else { continue }
          result.pulled += page.records.count
          if !page.hasMore {
            result.cursor = page.cursor
            result.rebuilding = false
            return true
          }
        }
      } catch let error as APIError
        where error.status == 410 && ["cursor_expired", "snapshot_expired"].contains(error.code)
      {
        _ = try await store.resetFeed(
          identity: identity, scope: scope, expectedRevision: state.revision,
          reconcile: error.code == "cursor_expired")
      }
    }
    result.hasMore = true
    return false
  }
  private func run(scope: SyncScope, maxPages: Int, limit: Int, expected: UUID, pullOnly: Bool)
    async throws
    -> SyncRunResult
  {
    var result = SyncRunResult()
    var pages = 0
    let store = try localStore()
    guard
      try await drain(
        scope: scope, maxPages: maxPages, limit: limit, expected: expected, pages: &pages,
        result: &result)
    else { return result }
    if pullOnly { return result }
    let pending = try await store.outbox(identity: identity).filter {
      scope.contains(collection: $0.mutation.collection, workspaceID: $0.mutation.workspaceId)
    }
    for entry in pending where entry.needsReconciliation {
      try await store.settlePush(
        identity: identity, sent: [entry],
        results: [
          .init(
            mutationId: entry.mutation.mutationId, collection: entry.mutation.collection,
            recordId: entry.mutation.recordId, status: "rejected", error: "requires_reconciliation")
        ])
      result.rejected += 1
    }
    var queue = pending.filter { !$0.needsReconciliation }[...]
    while let deliveryID = queue.first?.deliveryClientID {
      try check(expected)
      var batch: [OutboxEntry] = []
      var bytes = 0
      while let first = queue.first, first.deliveryClientID == deliveryID, batch.count < 128 {
        let size = try JSONEncoder().encode(first.mutation).count
        if !batch.isEmpty && bytes + size > 900_000 { break }
        batch.append(queue.removeFirst())
        bytes += size
      }
      let sent = try await store.preparePush(
        identity: identity, mutationIDs: batch.map { $0.mutation.mutationId })
      if sent.isEmpty { continue }
      let response = try await push(.init(clientId: deliveryID, mutations: sent.map(\.mutation)))
      try check(expected)
      try await store.settlePush(identity: identity, sent: sent, results: response.results)
      result.pushed += response.results.filter { $0.status == "applied" }.count
      result.conflicts += response.results.filter { $0.status == "conflict" }.count
      result.rejected += response.results.filter { $0.status == "rejected" }.count
    }
    if result.pushed > 0 {
      _ = try await drain(
        scope: scope, maxPages: maxPages, limit: limit, expected: expected, pages: &pages,
        result: &result)
    }
    if try await store.outbox(identity: identity).contains(where: {
      scope.contains(collection: $0.mutation.collection, workspaceID: $0.mutation.workspaceId)
    }) {
      result.hasMore = true
    }
    return result
  }
}
