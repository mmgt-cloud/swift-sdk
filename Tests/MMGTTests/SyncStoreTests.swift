import Foundation
import MMGTCore
import MMGTSync
import MMGTSyncSQLite
import Testing

@Suite(.timeLimit(.minutes(1))) struct SyncStoreTests {
  func configuration(_ host: String = "stage.example.invalid") throws -> ServiceConfiguration {
    try .init(baseURL: URL(string: "https://\(host)/sync")!, appID: "app-a")
  }
  func entry(_ id: String = "mutation-a", text: String = "offline", attempted: Bool = false)
    -> OutboxEntry
  {
    .init(
      mutation: .init(
        collection: "notes", recordId: "note-a", op: "upsert", data: ["text": .string(text)],
        mutationId: id, baseVersion: "0"), deliveryClientID: "original-device", attempted: attempted
    )
  }
  func change(_ version: String = "1", record: String = "note-a") -> SyncChange {
    .init(
      sequence: version, collection: "notes", recordId: record, op: "upsert", version: version,
      data: ["text": "server"], userId: "user-a", createdAt: "2026-09-09T12:00:00Z")
  }
  func path() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "mmgt-test-\(UUID())/sync.sqlite")
  }
  func seed(
    _ store: SQLiteSyncStore, _ identity: AccountIdentity, _ scope: SyncScope,
    _ changes: [SyncChange] = [], watermark: String = "1"
  ) async throws {
    let state = try await store.feed(identity: identity, scope: scope)
    #expect(
      try await store.commitSnapshotPage(
        identity: identity, scope: scope, expectedRevision: state.revision,
        page: .init(
          records: changes, watermark: watermark, cursor: "cursor-1", hasMore: false,
          expiresAt: "2030-01-01T00:00:00Z")))
  }

  @Test func outboxSurvivesRestartAndIsolatesEnvironmentAndAccount() async throws {
    let file = path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let identity = try AccountIdentity(configuration: configuration(), userID: "user-a")
    do {
      let first = try SQLiteSyncStore(fileURL: file)
      try await first.addOutbox(identity: identity, entries: [entry()])
    }
    let store = try SQLiteSyncStore(fileURL: file)
    let values = try await store.outbox(identity: identity)
    #expect(values.count == 1)
    #expect(values[0].deliveryClientID == "original-device")
    let prod = try AccountIdentity(
      configuration: configuration("prod.example.invalid"), userID: "user-a")
    let other = try AccountIdentity(configuration: configuration(), userID: "user-b")
    #expect(try await store.outbox(identity: prod).isEmpty)
    #expect(try await store.outbox(identity: other).isEmpty)
  }
  @Test func batchRollbackAndUncertainDeliveryCannotBeCoalesced() async throws {
    let file = path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = try SQLiteSyncStore(fileURL: file)
    let identity = try AccountIdentity(configuration: configuration(), userID: "user-a")
    try await store.addOutbox(identity: identity, entries: [entry()])
    await #expect(throws: SyncStoreError.mutationIDReused) {
      try await store.addOutbox(
        identity: identity, entries: [entry("new"), entry(text: "changed")])
    }
    #expect(try await store.outbox(identity: identity).map(\.mutation.mutationId) == ["mutation-a"])
    _ = try await store.preparePush(identity: identity, mutationIDs: ["mutation-a"])
    await #expect(throws: SyncStoreError.mutationAlreadyAttempted) {
      try await store.replaceRecordMutation(identity: identity, entry: entry("replacement"))
    }
    #expect(try await store.outbox(identity: identity).first?.attempted == true)
  }
  @Test func twoDatabaseConnectionsCannotCommitTheSameFeedRevision() async throws {
    let file = path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let a = try SQLiteSyncStore(fileURL: file)
    let b = try SQLiteSyncStore(fileURL: file)
    let identity = try AccountIdentity(configuration: configuration(), userID: "user-a")
    let scope = try SyncScope(collections: ["notes"])
    try await seed(a, identity, scope)
    let state = try await a.feed(identity: identity, scope: scope)
    async let first = a.commitPage(
      identity: identity, scope: scope, expectedRevision: state.revision,
      page: .init(changes: [change("9007199254740993")], nextCursor: "cursor-a", hasMore: false))
    async let second = b.commitPage(
      identity: identity, scope: scope, expectedRevision: state.revision,
      page: .init(changes: [change("9007199254740994")], nextCursor: "cursor-b", hasMore: false))
    let results = try await [first, second]
    #expect(results.filter { $0 }.count == 1)
    let committed = try await a.feed(identity: identity, scope: scope)
    let record = try await a.record(identity: identity, collection: "notes", id: "note-a")
    #expect(
      record?.version == (committed.cursor == "cursor-a" ? "9007199254740993" : "9007199254740994"))
    #expect(
      try await b.commitPage(
        identity: identity, scope: scope, expectedRevision: state.revision,
        page: .init(changes: [], nextCursor: "stale", hasMore: false)) == false)
  }
  @Test func snapshotIsAtomicAndPreservesNewerOverlappingFeedAndOutbox() async throws {
    let file = path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = try SQLiteSyncStore(fileURL: file)
    let identity = try AccountIdentity(configuration: configuration(), userID: "user-a")
    let all = try SyncScope()
    let notes = try SyncScope(collections: ["notes"])
    try await seed(store, identity, all, [change("1")])
    try await store.addOutbox(identity: identity, entries: [entry()])
    let start = try await store.feed(identity: identity, scope: notes)
    #expect(
      try await store.commitSnapshotPage(
        identity: identity, scope: notes, expectedRevision: start.revision,
        page: .init(
          records: [change("5")], watermark: "5", nextPage: "page-2", hasMore: true,
          expiresAt: "2030-01-01T00:00:00Z")))
    #expect(
      try await store.record(identity: identity, collection: "notes", id: "note-a")?.version == "1")
    let overlapping = try await store.feed(identity: identity, scope: all)
    #expect(
      try await store.commitPage(
        identity: identity, scope: all, expectedRevision: overlapping.revision,
        page: .init(changes: [change("7")], nextCursor: "all-7", hasMore: false)))
    let progress = try await store.feed(identity: identity, scope: notes)
    #expect(
      try await store.commitSnapshotPage(
        identity: identity, scope: notes, expectedRevision: progress.revision,
        page: .init(
          records: [], watermark: "5", cursor: "notes-5", hasMore: false,
          expiresAt: "2030-01-01T00:00:00Z")))
    #expect(
      try await store.record(identity: identity, collection: "notes", id: "note-a")?.version == "7")
    #expect(try await store.outbox(identity: identity).count == 1)
  }
  @Test func partialSettlementPreservesUnacknowledgedMutationsAndResolutionIsAtomic() async throws {
    let file = path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = try SQLiteSyncStore(fileURL: file)
    let identity = try AccountIdentity(configuration: configuration(), userID: "user-a")
    try await store.addOutbox(identity: identity, entries: [entry("a"), entry("b")])
    let prepared = try await store.preparePush(identity: identity, mutationIDs: ["a", "b"])
    try await store.settlePush(
      identity: identity, sent: prepared,
      results: [
        .init(
          mutationId: "a", collection: "notes", recordId: "note-a", status: "conflict",
          version: "2", conflictId: "conflict-a")
      ])
    #expect(try await store.outbox(identity: identity).map(\.mutation.mutationId) == ["b"])
    #expect(try await store.issues(identity: identity).first?.result.conflictId == "conflict-a")
    try await store.resolveIssue(
      identity: identity, mutationID: "a", replacement: entry("reconciled"))
    #expect(try await store.issues(identity: identity).isEmpty)
    #expect(
      try await store.outbox(identity: identity).map(\.mutation.mutationId) == ["b", "reconciled"])
  }
  @Test func expiredHistoryRecoversBeforeSendingOldWrites() async throws {
    let file = path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = try SQLiteSyncStore(fileURL: file)
    let config = try configuration()
    let identity = try AccountIdentity(configuration: config, userID: "user-a")
    let scope = try SyncScope(collections: ["notes"])
    try await seed(store, identity, scope)
    try await store.addOutbox(identity: identity, entries: [entry()])
    let page = SyncSnapshotResponse(
      records: [], watermark: "10", cursor: "recovered", hasMore: false,
      expiresAt: "2030-01-01T00:00:00Z")
    let transport = RecordingTransport([
      .init(data: Data(#"{"error":"cursor_expired"}"#.utf8), status: 410),
      .init(data: try JSONEncoder().encode(page), status: 200),
    ])
    let client = try SyncClient(
      configuration: config, userID: "user-a", tokenProvider: { "test-token" }, store: store,
      transport: transport)
    let result = try await client.sync(scope: scope)
    #expect(result.rejected == 1)
    #expect(result.pushed == 0)
    #expect(result.cursor == "recovered")
    #expect(
      try await store.issues(identity: identity).first?.result.error == "requires_reconciliation")
    #expect(await transport.requests.map(\.url!.lastPathComponent) == ["pull", "snapshot"])
  }
}
