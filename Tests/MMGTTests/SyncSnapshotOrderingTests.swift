import Foundation
import GRDB
import MMGTCore
import MMGTSync
import MMGTSyncSQLite
import Testing

@Suite(.timeLimit(.minutes(1))) struct SyncSnapshotOrderingTests {
  @Test func failedSnapshotCommitRollsBackRecordsFloorAndCursorTogether() async throws {
    let helpers = SyncStoreTests()
    let file = SyncStoreTests().path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let identity = try AccountIdentity(configuration: helpers.configuration(), userID: "user-a")
    let all = try SyncScope()
    let notes = try SyncScope(collections: ["notes"])
    let store = try SQLiteSyncStore(fileURL: file)
    try await helpers.seed(store, identity, all, [helpers.change("1")])
    let before = try await store.feed(identity: identity, scope: notes)
    let injector = try DatabaseQueue(path: file.path)
    try await injector.write { db in
      try db.execute(
        sql:
          "CREATE TRIGGER fail_snapshot_floor BEFORE INSERT ON snapshot_floors BEGIN SELECT RAISE(ABORT,'synthetic commit failure'); END"
      )
    }
    await #expect(throws: DatabaseError.self) {
      try await helpers.seed(store, identity, notes, [], watermark: "5")
    }
    #expect(try await store.feed(identity: identity, scope: notes) == before)
    #expect(
      try await store.record(identity: identity, collection: "notes", id: "note-a")?.version == "1")
    let overlapping = try await store.feed(identity: identity, scope: all)
    #expect(
      try await store.commitPage(
        identity: identity, scope: all, expectedRevision: overlapping.revision,
        page: .init(
          changes: [helpers.change("2")], nextCursor: "not-fenced-by-failed-snapshot",
          hasMore: false)))
    #expect(
      try await store.record(identity: identity, collection: "notes", id: "note-a")?.version == "2")
    try await injector.write { try $0.execute(sql: "DROP TRIGGER fail_snapshot_floor") }
    try await helpers.seed(store, identity, notes, [], watermark: "5")
    #expect(try await store.records(identity: identity, collection: "notes").isEmpty)
  }

  @Test func completedSnapshotFencesDelayedPullIncludingPreviouslyUnknownRecordsAfterRestart()
    async throws
  {
    let helpers = SyncStoreTests()
    let file = helpers.path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let identity = try AccountIdentity(configuration: helpers.configuration(), userID: "user-a")
    let all = try SyncScope()
    let notes = try SyncScope(collections: ["notes"])
    let slow = try SQLiteSyncStore(fileURL: file)
    try await helpers.seed(slow, identity, all, [helpers.change("1")])
    let waiting = try await slow.feed(identity: identity, scope: all)
    do {
      let fast = try SQLiteSyncStore(fileURL: file)
      try await helpers.seed(fast, identity, notes, [], watermark: "5")
    }
    let restarted = try SQLiteSyncStore(fileURL: file)
    #expect(
      try await restarted.commitPage(
        identity: identity, scope: all, expectedRevision: waiting.revision,
        page: .init(
          changes: [helpers.change("2"), helpers.change("3", record: "never-seen")],
          nextCursor: "older-page", hasMore: true)))
    #expect(try await restarted.records(identity: identity, collection: "notes").isEmpty)
    let resumed = try await restarted.feed(identity: identity, scope: all)
    #expect(resumed.cursor == "older-page")
    #expect(
      try await restarted.commitPage(
        identity: identity, scope: all, expectedRevision: resumed.revision,
        page: .init(changes: [helpers.change("6")], nextCursor: "new-page", hasMore: false)))
    #expect(
      try await restarted.record(identity: identity, collection: "notes", id: "note-a")?.version
        == "6")
  }

  @Test func olderOverlappingSnapshotCannotResurrectOrRemoveNewerSnapshotState() async throws {
    let helpers = SyncStoreTests()
    let file = helpers.path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = try SQLiteSyncStore(fileURL: file)
    let identity = try AccountIdentity(configuration: helpers.configuration(), userID: "user-a")
    let all = try SyncScope()
    let notes = try SyncScope(collections: ["notes"])
    let state = try await store.feed(identity: identity, scope: all)
    #expect(
      try await store.commitSnapshotPage(
        identity: identity, scope: all, expectedRevision: state.revision,
        page: .init(
          records: [helpers.change("2", record: "deleted")], watermark: "3",
          nextPage: "old-snapshot-next", hasMore: true, expiresAt: "2030-01-01T00:00:00Z")))
    try await helpers.seed(
      store, identity, notes, [helpers.change("1", record: "still-present")], watermark: "5")
    let progress = try await store.feed(identity: identity, scope: all)
    #expect(
      try await store.commitSnapshotPage(
        identity: identity, scope: all, expectedRevision: progress.revision,
        page: .init(
          records: [], watermark: "3", cursor: "old-snapshot-end",
          hasMore: false, expiresAt: "2030-01-01T00:00:00Z")))
    #expect(try await store.record(identity: identity, collection: "notes", id: "deleted") == nil)
    #expect(
      try await store.record(identity: identity, collection: "notes", id: "still-present")?.version
        == "1")
  }
}
