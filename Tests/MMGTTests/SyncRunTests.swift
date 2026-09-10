import Foundation
import MMGTCore
import MMGTSync
import MMGTSyncSQLite
import Testing

@Suite(.timeLimit(.minutes(1))) struct SyncRunTests {
  private func response<T: Encodable>(_ value: T) throws -> HTTPResponse {
    .init(data: try JSONEncoder().encode(value), status: 200)
  }
  @Test func explicitRebuildRetainsIssuesAndLocalEditsRequireFreshMutationIdentity() async throws {
    let helper = SyncStoreTests()
    let file = SyncStoreTests().path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let config = try helper.configuration()
    let identity = try AccountIdentity(configuration: config, userID: "user-a")
    let scope = try SyncScope(collections: ["notes"])
    let store = try SQLiteSyncStore(fileURL: file)
    try await helper.seed(store, identity, scope)
    let transport = RecordingTransport([
      try response(
        SyncSnapshotResponse(
          records: [], watermark: "9", cursor: "rebuilt", hasMore: false,
          expiresAt: "2030-01-01T00:00:00Z"))
    ])
    let sdk = try SyncClient(
      configuration: config, userID: "user-a", tokenProvider: { "synthetic" }, store: store,
      transport: transport)
    let first = try await sdk.write(
      .init(
        collection: "notes", recordId: "note-a", op: "upsert", data: ["title": "one"],
        baseVersion: "0"))
    #expect(!first.mutation.mutationId.isEmpty)
    try await sdk.replaceLocalMutation(
      .init(
        collection: "notes", recordId: "note-a", op: "upsert", data: ["title": "two"],
        mutationId: "replacement", baseVersion: "0"))
    #expect(try await sdk.listLocalOutbox().map(\.mutation.mutationId) == ["replacement"])
    let result = try await sdk.rebuild(scope: scope)
    #expect(result.rejected == 1 && result.cursor == "rebuilt" && result.pushed == 0)
    #expect(try await sdk.listLocalConflicts().first?.entry.mutation.data?["title"] == "two")
    try await sdk.resolveLocalConflict(
      "replacement",
      replacement: .init(
        collection: "notes", recordId: "note-a", op: "upsert", data: ["title": "reviewed"],
        mutationId: "replacement", baseVersion: "0"))
    let retry = try #require(await sdk.listLocalOutbox().first)
    #expect(
      retry.mutation.mutationId != "replacement" && !retry.attempted && !retry.needsReconciliation)
    #expect(try await sdk.listLocalConflicts().isEmpty)
    try await sdk.removeLocalOutbox([retry.mutation.mutationId])
    #expect(try await sdk.listLocalOutbox().isEmpty)
    #expect(await transport.requests.map(\.url!.lastPathComponent) == ["snapshot"])
  }
  @Test func boundedSnapshotResumesAfterRestartAndPartialPushKeepsOriginalIDsAndCursor()
    async throws
  {
    let helper = SyncStoreTests()
    let file = SyncStoreTests().path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let config = try helper.configuration()
    let identity = try AccountIdentity(configuration: config, userID: "user-a")
    let scope = try SyncScope(collections: ["notes"])
    let transport = RecordingTransport(
      try [
        response(
          SyncSnapshotResponse(
            records: [helper.change()], watermark: "5", nextPage: "frozen-page-2", hasMore: true,
            expiresAt: "2030-01-01T00:00:00Z")),
        response(
          SyncSnapshotResponse(
            records: [], watermark: "5", cursor: "snapshot-5", hasMore: false,
            expiresAt: "2030-01-01T00:00:00Z")),
        response(
          SyncPushResponse(results: [
            .init(
              mutationId: "a", collection: "notes", recordId: "note-a", status: "applied",
              version: "6")
          ])),
        response(
          SyncPullResponse(changes: [helper.change("6")], nextCursor: "pull-6", hasMore: false)),
        response(
          SyncPushResponse(results: [
            .init(
              mutationId: "b", collection: "notes", recordId: "note-b", status: "rejected",
              error: "schema_validation_failed")
          ])),
      ])
    do {
      let store = try SQLiteSyncStore(fileURL: file)
      let sdk = try SyncClient(
        configuration: config, userID: "user-a", tokenProvider: { "synthetic" }, store: store,
        clientID: "original-device", transport: transport)
      try await sdk.writeBatch([
        .init(
          collection: "notes", recordId: "note-a", op: "upsert", mutationId: "a", baseVersion: "0"),
        .init(
          collection: "notes", recordId: "note-b", op: "upsert", mutationId: "b", baseVersion: "0"),
      ])
      let first = try await sdk.sync(scope: scope, maxPages: 1)
      #expect(first.hasMore && first.rebuilding && first.pushed == 0)
      #expect(try await sdk.listLocalRecords(collection: "notes").isEmpty)
      #expect(try await sdk.listLocalOutbox().count == 2)
    }
    let store = try SQLiteSyncStore(fileURL: file)
    let sdk = try SyncClient(
      configuration: config, userID: "user-a", tokenProvider: { "synthetic" }, store: store,
      clientID: "new-process", transport: transport)
    let second = try await sdk.sync(scope: scope, maxPages: 1)
    #expect(second.hasMore && second.pushed == 1 && second.cursor == "snapshot-5")
    #expect(try await sdk.getLocalRecord(collection: "notes", id: "note-a")?.version == "1")
    #expect(try await sdk.listLocalOutbox().map(\.mutation.mutationId) == ["b"])
    let third = try await sdk.sync(scope: scope)
    #expect(!third.hasMore && third.rejected == 1 && third.cursor == "pull-6")
    #expect(try await sdk.listLocalOutbox().isEmpty)
    #expect(try await sdk.listLocalConflicts().first?.result.error == "schema_validation_failed")
    let requests = await transport.requests
    #expect(
      requests.map(\.url!.lastPathComponent) == ["snapshot", "snapshot", "push", "pull", "push"])
    #expect(
      try JSONDecoder().decode(SyncSnapshotRequest.self, from: requests[1].httpBody!).pageToken
        == "frozen-page-2")
    #expect(
      try JSONDecoder().decode(SyncPullRequest.self, from: requests[3].httpBody!).cursor
        == "snapshot-5")
    for index in [2, 4] {
      #expect(
        try JSONDecoder().decode(SyncPushRequest.self, from: requests[index].httpBody!).clientId
          == "original-device")
    }
    try await sdk.clearLocalConflicts(["b"])
    #expect(try await sdk.listLocalConflicts().isEmpty)
    #expect(try await store.feed(identity: identity, scope: scope).cursor == "pull-6")
  }

  @Test(arguments: ["cancelPending", "close", "taskCancellation"])
  func lateNoncooperativeResponseCannotCommitAfterCancellation(_ action: String) async throws {
    let helper = SyncStoreTests()
    let file = SyncStoreTests().path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let config = try helper.configuration()
    let identity = try AccountIdentity(configuration: config, userID: "user-a")
    let scope = try SyncScope(collections: ["notes"])
    let store = try SQLiteSyncStore(fileURL: file)
    try await helper.seed(store, identity, scope)
    let before = try await store.feed(identity: identity, scope: scope)
    let transport = ControlledTransport()
    let sdk = try SyncClient(
      configuration: config, userID: "user-a", tokenProvider: { "synthetic" }, store: store,
      transport: transport)
    let task = Task { try await sdk.sync(scope: scope) }
    await transport.waitForRequest(0)
    if action == "close" {
      await sdk.close()
    } else if action == "cancelPending" {
      await sdk.cancelPending()
    } else {
      task.cancel()
    }
    let page = SyncPullResponse(
      changes: [helper.change("9")], nextCursor: "stale-response", hasMore: false)
    await transport.reply(0, String(decoding: try JSONEncoder().encode(page), as: UTF8.self))
    await #expect(throws: (any Error).self) { _ = try await task.value }
    #expect(try await store.feed(identity: identity, scope: scope) == before)
    #expect(try await store.records(identity: identity, collection: "notes").isEmpty)
    if action == "close" {
      await #expect(throws: MMGTError.sessionChanged) { _ = try await sdk.pull() }
    } else {
      let next = Task { try await sdk.pull(.init(collections: ["notes"])) }
      await transport.waitForRequest(1)
      await transport.reply(1, #"{"changes":[],"next_cursor":"fresh","has_more":false}"#)
      #expect(try await next.value.nextCursor == "fresh")
    }
  }
}
