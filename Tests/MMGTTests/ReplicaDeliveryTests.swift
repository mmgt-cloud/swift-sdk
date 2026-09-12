import Foundation
import GRDB
import MMGTCore
import MMGTSync
import Testing

@testable import MMGTSyncSQLite

/// Synthetic server: enforces exact CAS, immutable dedupe payloads and expected subject headers.
private actor ReplicaServer: HTTPTransport {
  var changes: [SyncChange] = []
  var processed: [String: (SyncMutationPayload, SyncPushResult)] = [:]
  var requests: [URLRequest] = []
  var loseNextPush = false
  var userID = "user-a"
  let helper = ReplicaTests()
  func configure(loss: Bool = false, user: String = "user-a") {
    loseNextPush = loss
    userID = user
  }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.append(request)
    guard request.value(forHTTPHeaderField: "X-Sync-User-ID") == userID else {
      throw APIError(
        status: 403, code: "sync_identity_mismatch", message: "Synthetic identity changed")
    }
    switch request.url!.lastPathComponent {
    case "bootstrap": return try helper.response(helper.bootstrap(userID))
    case "snapshot":
      return try helper.response(
        helper.snapshotResponse(changes, version: changes.last?.version ?? "0"))
    case "pull":
      return try helper.response(
        SyncPullResponse(changes: changes, nextCursor: "feed-\(changes.count)", hasMore: false))
    case "push":
      let body = try JSONDecoder().decode(SyncPushRequest.self, from: request.httpBody!)
      var results: [SyncPushResult] = []
      for mutation in body.mutations {
        let key = body.clientId + "/" + mutation.mutationId
        if let existing = processed[key] {
          guard existing.0 == mutation else { throw SyncStoreError.mutationIDReused }
          results.append(existing.1)
          continue
        }
        let previous = changes.last {
          $0.collection == mutation.collection && $0.recordId == mutation.recordId
        }
        guard mutation.baseVersion == previous?.version ?? "0" else {
          throw SyncStoreError.invalidVersion
        }
        let version = String(changes.count + 1)
        changes.append(
          .init(
            sequence: version, collection: mutation.collection, recordId: mutation.recordId,
            op: mutation.op, version: version, data: mutation.data, userId: userID,
            createdAt: "2026-09-12T00:00:00Z"))
        let result = SyncPushResult(
          mutationId: mutation.mutationId, collection: mutation.collection,
          recordId: mutation.recordId, status: "applied", version: version)
        processed[key] = (mutation, result)
        results.append(result)
      }
      if loseNextPush {
        loseNextPush = false
        throw URLError(.networkConnectionLost)
      }
      return try helper.response(SyncPushResponse(results: results))
    default: throw MMGTError.invalidResponse("Unexpected request")
    }
  }
}

@Suite(.timeLimit(.minutes(1))) struct ReplicaDeliveryTests {
  let helper = ReplicaTests()
  @Test func GuestImportThenLostPushAndRestartConvergesOnAnotherDevice() async throws {
    let file = helper.helper.path()
    let secondFile = helper.helper.path()
    defer {
      try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
      try? FileManager.default.removeItem(at: secondFile.deletingLastPathComponent())
    }
    let store = try SQLiteSyncStore(fileURL: file)
    let server = ReplicaServer()
    let target = try helper.identity(.user("user-a"))
    let guest = try helper.replica(store)
    let user = try helper.replica(store, target)
    try await guest.upsert(collection: "notes", id: "n", data: ["text": "local AI tool"])
    try await user.connect(tokenProvider: { "ordinary-jwt" }, transport: server)
    let plan = try await guest.prepareImport(to: user)
    #expect(!plan.requiresConfirmation)
    let committed = try await guest.approveImport(plan.id, to: user)
    await server.configure(loss: true)
    await #expect(throws: (any Error).self) { _ = try await user.synchronize() }
    #expect(await server.changes.count == 1)
    #expect(try await user.snapshot().outbox.first?.attempted == true)
    await user.close()
    let resumed = try helper.replica(SQLiteSyncStore(fileURL: file), target)
    try await resumed.connect(tokenProvider: { "ordinary-jwt" }, transport: server)
    let result = try await resumed.synchronize()
    #expect(result.pushed == 1 && !result.hasMore)
    #expect(await server.changes.count == 1)
    #expect(try await guest.importProgress(committed.id).applied == 1)
    #expect(try await guest.get(collection: "notes", id: "n")?.data?["text"] == "local AI tool")
    let other = try helper.replica(SQLiteSyncStore(fileURL: secondFile), target)
    try await other.connect(tokenProvider: { "ordinary-jwt" }, transport: server)
    _ = try await other.synchronize()
    #expect(try await other.get(collection: "notes", id: "n")?.data?["text"] == "local AI tool")
    let firstRequests = await server.requests.filter { $0.url?.lastPathComponent == "push" }
    try #require(firstRequests.count == 2)
    // JSON object key order is irrelevant; delivery ID and the full mutation payload must be unchanged.
    #expect(
      try JSONDecoder().decode(SyncPushRequest.self, from: firstRequests[0].httpBody!)
        == JSONDecoder().decode(SyncPushRequest.self, from: firstRequests[1].httpBody!))
  }
  @Test func PartialRecordChainReturnsHasMoreUntilNextConfirmedCAS() async throws {
    let file = helper.helper.path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = try SQLiteSyncStore(fileURL: file)
    let user = try helper.replica(store, helper.identity(.user("user-a")))
    let server = ReplicaServer()
    try await user.upsert(collection: "notes", id: "n", data: ["text": "first"])
    try await user.upsert(collection: "notes", id: "n", data: ["text": "second"])
    try await user.connect(tokenProvider: { "ordinary-jwt" }, transport: server)
    let first = try await user.synchronize()
    #expect(first.pushed == 1 && first.hasMore)
    #expect(try await user.get(collection: "notes", id: "n")?.data?["text"] == "second")
    let second = try await user.synchronize()
    #expect(second.pushed == 1 && !second.hasMore)
    #expect(try await user.get(collection: "notes", id: "n")?.serverVersion == "2")
    await server.configure(user: "user-b")
    let count = await server.requests.count
    await #expect(throws: APIError.self) { _ = try await user.synchronize() }
    #expect(await server.requests.count == count + 1)
    #expect(await server.changes.count == 2)
  }
  @Test func LogoutWhileBootstrapIgnoresCancellationCannotAttachNewSession() async throws {
    let file = helper.helper.path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let user = try helper.replica(SQLiteSyncStore(fileURL: file), helper.identity(.user("user-a")))
    let network = ControlledTransport()
    let connecting = Task { try await user.connect(tokenProvider: { "jwt" }, transport: network) }
    await network.waitForRequest(0)
    await user.close()
    await network.reply(
      0, String(data: try JSONEncoder().encode(helper.bootstrap()), encoding: .utf8)!)
    await #expect(throws: ReplicaError.closed) { try await connecting.value }
    await #expect(throws: ReplicaError.closed) { _ = try await user.synchronize() }
    await #expect(throws: ReplicaError.closed) {
      try await user.upsert(collection: "notes", id: "late-ai", data: [:])
    }
  }
}

@Suite(.timeLimit(.minutes(1))) struct ReplicaDiskTests {
  @Test func RealSQLiteFullRollsBackJournalAndQueue() async throws {
    let helper = ReplicaTests()
    let file = SyncStoreTests().path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = try SQLiteSyncStore(fileURL: file)
    let local = try helper.replica(store, helper.identity(.user("user-a")))
    let before = try await local.snapshot()
    try await store.database.writeWithoutTransaction { db in
      let pages = try Int.fetchOne(db, sql: "PRAGMA page_count")!
      try db.execute(sql: "PRAGMA max_page_count = \(pages)")
    }
    do {
      try await local.upsert(
        collection: "notes", id: "large",
        data: ["text": .string(String(repeating: "x", count: 300_000))])
      Issue.record("Expected SQLITE_FULL")
    } catch let error as DatabaseError { #expect(error.resultCode == .SQLITE_FULL) }
    #expect(try await local.snapshot() == before)
  }
}
