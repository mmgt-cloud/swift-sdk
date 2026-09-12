import CryptoKit
import Foundation
import GRDB
import MMGTCore
import MMGTSync
import MMGTSyncSQLite
import Testing

@Suite struct SyncMigrationTests {
  private func bytes<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }
  private func key<T: Encodable>(_ value: T) throws -> String {
    SHA256.hash(data: try bytes(value)).map { String(format: "%02x", $0) }.joined()
  }
  @Test func v1MigrationRebuildsOnceAndRetainsAccountOwnedQueueAndIssues() async throws {
    let helpers = SyncStoreTests()
    let file = helpers.path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let identity = try AccountIdentity(configuration: helpers.configuration(), userID: "user-a")
    let scope = try SyncScope(collections: ["notes"])
    let i = try key(identity)
    let s = try key(scope)
    let entry = helpers.entry(attempted: true)
    let issue = SyncIssue(
      entry: helpers.entry("conflict"),
      result: .init(
        mutationId: "conflict", collection: "notes", recordId: "note-a", status: "conflict",
        version: "1", conflictId: "server-conflict"))
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    do {
      let legacy = try DatabaseQueue(path: file.path)
      // Frozen v1 layout: independent of the current migrator being tested.
      try await legacy.write { db in
        try db.execute(
          sql: """
            CREATE TABLE grdb_migrations(identifier TEXT NOT NULL PRIMARY KEY);
            INSERT INTO grdb_migrations VALUES('v1');
            CREATE TABLE feeds(identity TEXT NOT NULL,scope TEXT NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(identity,scope));
            CREATE TABLE records(identity TEXT NOT NULL,collection TEXT NOT NULL,record_id TEXT NOT NULL,workspace TEXT NOT NULL,version TEXT NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(identity,collection,record_id));
            CREATE TABLE snapshot_records(identity TEXT NOT NULL,scope TEXT NOT NULL,collection TEXT NOT NULL,record_id TEXT NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(identity,scope,collection,record_id));
            CREATE TABLE outbox(ordinal INTEGER PRIMARY KEY AUTOINCREMENT,identity TEXT NOT NULL,mutation_id TEXT NOT NULL,payload BLOB NOT NULL,UNIQUE(identity,mutation_id));
            CREATE TABLE issues(identity TEXT NOT NULL,mutation_id TEXT NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(identity,mutation_id));
            """)
        try db.execute(
          sql: "INSERT INTO feeds VALUES(?,?,?)",
          arguments: [i, s, try bytes(SyncFeedState(revision: "legacy", cursor: "unsafe-cursor"))])
        try db.execute(
          sql: "INSERT INTO outbox(identity,mutation_id,payload) VALUES(?,?,?)",
          arguments: [i, entry.mutation.mutationId, try bytes(entry)])
        try db.execute(
          sql: "INSERT INTO issues VALUES(?,?,?)", arguments: [i, "conflict", try bytes(issue)])
        try db.execute(
          sql: "INSERT INTO snapshot_records VALUES(?,?,?,?,?)",
          arguments: [i, s, "notes", "staged", try bytes(helpers.change())])
      }
    }
    let store = try SQLiteSyncStore(fileURL: file)
    #expect(try await store.feed(identity: identity, scope: scope) == .init())
    let pending = try #require(await store.outbox(identity: identity).first)
    #expect(
      pending.mutation == entry.mutation && pending.deliveryClientID == entry.deliveryClientID
        && pending.createdAt == entry.createdAt)
    #expect(pending.attempted && pending.needsReconciliation)
    #expect(try await store.issues(identity: identity) == [issue])
    let other = try AccountIdentity(configuration: helpers.configuration(), userID: "user-b")
    #expect(try await store.outbox(identity: other).isEmpty)
    #expect(try await store.issues(identity: other).isEmpty)
    try await helpers.seed(store, identity, scope, [], watermark: "5")
    #expect(try await store.records(identity: identity, collection: "notes").isEmpty)
    let state = try await store.feed(identity: identity, scope: scope)
    let reopened = try SQLiteSyncStore(fileURL: file)
    #expect(try await reopened.feed(identity: identity, scope: scope) == state)
    #expect(try await reopened.issues(identity: identity) == [issue])
  }
  @Test func v2UpgradePreservesSafeFeedsAndOriginalAttemptedWireWithoutGuestAssignment()
    async throws
  {
    let helper = SyncStoreTests()
    let file = SyncStoreTests().path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let config = try helper.configuration()
    let identity = try AccountIdentity(configuration: config, userID: "user-a")
    let scope = try SyncScope(collections: ["notes"])
    let i = try key(identity)
    let scopeKey = try key(scope)
    let original = helper.entry(attempted: true)
    let feed = SyncFeedState(revision: "v2-safe", cursor: "opaque-v2")
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let old = try DatabaseQueue(path: file.path)
    try await old.write { db in
      try db.execute(
        sql: """
          CREATE TABLE grdb_migrations(identifier TEXT NOT NULL PRIMARY KEY);
          INSERT INTO grdb_migrations VALUES('v1'),('v2-snapshot-floors');
          CREATE TABLE feeds(identity TEXT NOT NULL,scope TEXT NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(identity,scope));
          CREATE TABLE records(identity TEXT NOT NULL,collection TEXT NOT NULL,record_id TEXT NOT NULL,workspace TEXT NOT NULL,version TEXT NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(identity,collection,record_id));
          CREATE TABLE snapshot_records(identity TEXT NOT NULL,scope TEXT NOT NULL,collection TEXT NOT NULL,record_id TEXT NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(identity,scope,collection,record_id));
          CREATE TABLE outbox(ordinal INTEGER PRIMARY KEY AUTOINCREMENT,identity TEXT NOT NULL,mutation_id TEXT NOT NULL,payload BLOB NOT NULL,UNIQUE(identity,mutation_id));
          CREATE TABLE issues(identity TEXT NOT NULL,mutation_id TEXT NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(identity,mutation_id));
          CREATE TABLE snapshot_floors(identity TEXT NOT NULL,scope TEXT NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(identity,scope));
          """)
      try db.execute(
        sql: "INSERT INTO feeds VALUES(?,?,?)", arguments: [i, scopeKey, try bytes(feed)])
      try db.execute(
        sql: "INSERT INTO outbox(identity,mutation_id,payload) VALUES(?,?,?)",
        arguments: [i, original.mutation.mutationId, try bytes(original)])
    }
    let store = try SQLiteSyncStore(fileURL: file)
    let state = try await store.replicaSnapshot(
      identity: .init(configuration: config, principal: .user("user-a")))
    #expect(state.metadata.journal.first?.entry == original && state.outbox == [original])
    #expect(try await store.feed(identity: identity, scope: scope) == feed)
    #expect(
      try await store.replicaSnapshot(
        identity: .init(configuration: config, principal: .guest("user-a"))
      ).records.isEmpty)
    #expect(try await SQLiteSyncStore(fileURL: file).outbox(identity: identity) == [original])
  }

}
