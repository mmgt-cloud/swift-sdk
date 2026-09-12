import CryptoKit
import Foundation
import GRDB
import MMGTCore
import MMGTSync

/// A WAL database with transactionally fenced feeds, staged snapshots and a durable per-account outbox.
public final class SQLiteSyncStore: ReplicaLocalStore, Sendable {
  let database: DatabaseQueue
  public init(fileURL: URL) throws {
    guard fileURL.isFileURL else {
      throw MMGTError.invalidConfiguration("SQLite requires a local file URL")
    }
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var config = Configuration()
    config.busyMode = .timeout(5)
    // One async queue matches the store's atomic operations and avoids a pool
    // semaphore between foreground reads. Separate store instances use WAL/CAS.
    config.prepareDatabase { db in try db.execute(sql: "PRAGMA journal_mode = WAL") }
    database = try DatabaseQueue(path: fileURL.path, configuration: config)
    var migrations = DatabaseMigrator()
    migrations.registerMigration("v1") { db in
      try db.execute(
        sql: """
          CREATE TABLE feeds (identity TEXT NOT NULL, scope TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(identity, scope));
          CREATE TABLE records (identity TEXT NOT NULL, collection TEXT NOT NULL, record_id TEXT NOT NULL, workspace TEXT NOT NULL, version TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(identity, collection, record_id));
          CREATE TABLE snapshot_records (identity TEXT NOT NULL, scope TEXT NOT NULL, collection TEXT NOT NULL, record_id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(identity, scope, collection, record_id));
          CREATE TABLE outbox (ordinal INTEGER PRIMARY KEY AUTOINCREMENT, identity TEXT NOT NULL, mutation_id TEXT NOT NULL, payload BLOB NOT NULL, UNIQUE(identity, mutation_id));
          CREATE TABLE issues (identity TEXT NOT NULL, mutation_id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(identity, mutation_id));
          """)
    }
    migrations.registerMigration("v2-snapshot-floors") { db in
      try db.execute(
        sql:
          "CREATE TABLE snapshot_floors (identity TEXT NOT NULL, scope TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(identity, scope))"
      )
      // v1 did not retain authoritative absence after a snapshot. Rebuild feeds,
      // keeping visible data and every pending/conflicted mutation until recovery.
      try db.execute(sql: "DELETE FROM feeds; DELETE FROM snapshot_records")
      for row in try Row.fetchAll(db, sql: "SELECT ordinal,payload FROM outbox") {
        var entry: OutboxEntry = try Self.decode(row["payload"])
        entry.needsReconciliation = true
        try db.execute(
          sql: "UPDATE outbox SET payload=? WHERE ordinal=?",
          arguments: [try Self.encoded(entry), row["ordinal"] as Int64])
      }
    }
    migrations.registerMigration("v3-local-replica") { db in
      try db.execute(
        sql: """
          CREATE TABLE replica_metadata (identity TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL);
          CREATE TABLE replica_imports (id TEXT PRIMARY KEY NOT NULL, source TEXT NOT NULL, payload BLOB NOT NULL);
          """)
    }
    try migrations.migrate(database)
    var resourceURL = fileURL
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try resourceURL.setResourceValues(values)
  }
  static func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }
  static func key<T: Encodable>(_ value: T) throws -> String {
    SHA256.hash(data: try encoded(value)).map { String(format: "%02x", $0) }.joined()
  }
  static func decode<T: Decodable>(_ data: Data) throws -> T {
    try JSONDecoder().decode(T.self, from: data)
  }
  static func loadFeed(_ db: Database, _ identity: String, _ scope: String) throws
    -> SyncFeedState
  {
    guard
      let data = try Data.fetchOne(
        db, sql: "SELECT payload FROM feeds WHERE identity=? AND scope=?",
        arguments: [identity, scope])
    else { return .init() }
    return try decode(data)
  }
  static func saveFeed(
    _ db: Database, _ identity: String, _ scope: String, _ state: SyncFeedState
  ) throws {
    var state = state
    state.revision = UUID().uuidString
    try touchReplica(db, identity)
    try db.execute(
      sql:
        "INSERT INTO feeds VALUES(?,?,?) ON CONFLICT(identity,scope) DO UPDATE SET payload=excluded.payload",
      arguments: [identity, scope, try encoded(state)])
  }
  public func feed(identity: AccountIdentity, scope: SyncScope) async throws -> SyncFeedState {
    let i = try Self.key(identity)
    let s = try Self.key(scope)
    return try await database.read { try Self.loadFeed($0, i, s) }
  }
  struct SnapshotFloor: Codable {
    let scope: SyncScope
    let watermark: String
  }
  static func floors(_ db: Database, _ identity: String) throws -> [SnapshotFloor] {
    try Data.fetchAll(
      db, sql: "SELECT payload FROM snapshot_floors WHERE identity=?",
      arguments: [identity]
    ).map(Self.decode)
  }
  static func superseded(
    collection: String, workspaceID: String?, version: String, snapshotWatermark: String?,
    floors: [SnapshotFloor]
  ) throws -> Bool {
    for floor in floors where floor.scope.contains(collection: collection, workspaceID: workspaceID)
    {
      if let snapshotWatermark {
        if try SyncVersions.less(snapshotWatermark, than: floor.watermark) { return true }
      } else if !(try SyncVersions.less(floor.watermark, than: version)) {
        return true
      }
    }
    return false
  }
  static func saveRecord(
    _ db: Database, _ identity: String, _ change: SyncChange, floors: [SnapshotFloor],
    snapshotWatermark: String? = nil
  ) throws {
    // A completed snapshot proves absence too, including records never seen here.
    if try superseded(
      collection: change.collection, workspaceID: change.workspaceId,
      version: change.version, snapshotWatermark: snapshotWatermark, floors: floors)
    {
      return
    }
    if let old = try Row.fetchOne(
      db,
      sql:
        "SELECT workspace,version FROM records WHERE identity=? AND collection=? AND record_id=?",
      arguments: [identity, change.collection, change.recordId])
    {
      let workspace: String = old["workspace"]
      let version: String = old["version"]
      guard workspace == (change.workspaceId ?? "") else { throw SyncStoreError.invalidChange }
      if !(try SyncVersions.less(version, than: change.version)) { return }
    }
    let value = SyncRecord(
      collection: change.collection, id: change.recordId, version: change.version,
      data: change.data, deleted: change.op == "delete", workspaceId: change.workspaceId,
      updatedAt: change.createdAt)
    try db.execute(
      sql:
        "INSERT INTO records VALUES(?,?,?,?,?,?) ON CONFLICT(identity,collection,record_id) DO UPDATE SET workspace=excluded.workspace,version=excluded.version,payload=excluded.payload",
      arguments: [
        identity, change.collection, change.recordId, change.workspaceId ?? "", change.version,
        try encoded(value),
      ])
  }
  public func commitPage(
    identity: AccountIdentity, scope: SyncScope, expectedRevision: String, page: SyncPullResponse
  ) async throws -> Bool {
    let i = try Self.key(identity)
    let s = try Self.key(scope)
    for change in page.changes { try validateSyncChange(change, identity: identity, scope: scope) }
    guard !page.nextCursor.isEmpty else { throw SyncStoreError.invalidChange }
    return try await database.write { db in
      let state = try Self.loadFeed(db, i, s)
      guard state.revision == expectedRevision, state.cursor != nil else { return false }
      let floors = try Self.floors(db, i)
      for change in page.changes { try Self.saveRecord(db, i, change, floors: floors) }
      try Self.saveFeed(db, i, s, .init(cursor: page.nextCursor))
      return true
    }
  }
  public func commitSnapshotPage(
    identity: AccountIdentity, scope: SyncScope, expectedRevision: String,
    page: SyncSnapshotResponse
  ) async throws -> Bool {
    let i = try Self.key(identity)
    let s = try Self.key(scope)
    try SyncVersions.validate(page.watermark)
    let expiry = try WireDate.parse(page.expiresAt)
    guard expiry > Date() else {
      throw APIError(
        status: 410, code: "snapshot_expired",
        message: "Snapshot expired before its page could be committed")
    }
    for change in page.records {
      try validateSyncChange(change, identity: identity, scope: scope)
      guard !(try SyncVersions.less(page.watermark, than: change.version)) else {
        throw SyncStoreError.invalidChange
      }
    }
    guard page.hasMore ? !(page.nextPage ?? "").isEmpty : !(page.cursor ?? "").isEmpty else {
      throw SyncStoreError.invalidChange
    }
    return try await database.write { db in
      let state = try Self.loadFeed(db, i, s)
      guard state.revision == expectedRevision, state.cursor == nil else { return false }
      if let progress = state.snapshot,
        progress.watermark != page.watermark || progress.expiresAt != page.expiresAt
      {
        throw SyncStoreError.invalidChange
      }
      for change in page.records {
        if let workspace = try String.fetchOne(
          db,
          sql: "SELECT workspace FROM records WHERE identity=? AND collection=? AND record_id=?",
          arguments: [i, change.collection, change.recordId]),
          workspace != (change.workspaceId ?? "")
        {
          throw SyncStoreError.invalidChange
        }
        try db.execute(
          sql:
            "INSERT INTO snapshot_records VALUES(?,?,?,?,?) ON CONFLICT(identity,scope,collection,record_id) DO UPDATE SET payload=excluded.payload",
          arguments: [i, s, change.collection, change.recordId, try Self.encoded(change)])
      }
      if page.hasMore {
        try Self.saveFeed(
          db, i, s,
          .init(
            snapshot: .init(
              nextPage: page.nextPage!, watermark: page.watermark, expiresAt: page.expiresAt)))
      } else {
        let floors = try Self.floors(db, i)
        // Other scopes may have fetched records newer than this snapshot. Preserve those.
        for row in try Row.fetchAll(
          db, sql: "SELECT collection,record_id,workspace,version FROM records WHERE identity=?",
          arguments: [i])
        {
          let collection: String = row["collection"]
          let id: String = row["record_id"]
          let workspace: String = row["workspace"]
          let version: String = row["version"]
          if scope.contains(collection: collection, workspaceID: workspace),
            !(try SyncVersions.less(page.watermark, than: version)),
            !(try Self.superseded(
              collection: collection, workspaceID: workspace,
              version: version, snapshotWatermark: page.watermark, floors: floors))
          {
            try db.execute(
              sql: "DELETE FROM records WHERE identity=? AND collection=? AND record_id=?",
              arguments: [i, collection, id])
          }
        }
        for data in try Data.fetchAll(
          db, sql: "SELECT payload FROM snapshot_records WHERE identity=? AND scope=?",
          arguments: [i, s])
        {
          let change: SyncChange = try Self.decode(data)
          try Self.saveRecord(db, i, change, floors: floors, snapshotWatermark: page.watermark)
        }
        var retainedWatermark = page.watermark
        if let old = floors.first(where: { $0.scope == scope }),
          try SyncVersions.less(page.watermark, than: old.watermark)
        {
          retainedWatermark = old.watermark
        }
        try db.execute(
          sql:
            "INSERT INTO snapshot_floors VALUES(?,?,?) ON CONFLICT(identity,scope) DO UPDATE SET payload=excluded.payload",
          arguments: [
            i, s, try Self.encoded(SnapshotFloor(scope: scope, watermark: retainedWatermark)),
          ])
        try db.execute(
          sql: "DELETE FROM snapshot_records WHERE identity=? AND scope=?", arguments: [i, s])
        try Self.saveFeed(db, i, s, .init(cursor: page.cursor))
      }
      return true
    }
  }
  public func resetFeed(
    identity: AccountIdentity, scope: SyncScope, expectedRevision: String, reconcile: Bool
  ) async throws -> Bool {
    let i = try Self.key(identity)
    let s = try Self.key(scope)
    return try await database.write { db in
      guard try Self.loadFeed(db, i, s).revision == expectedRevision else { return false }
      try db.execute(
        sql: "DELETE FROM snapshot_records WHERE identity=? AND scope=?", arguments: [i, s])
      if reconcile {
        for data in try Data.fetchAll(
          db, sql: "SELECT payload FROM outbox WHERE identity=?", arguments: [i])
        {
          var entry: OutboxEntry = try Self.decode(data)
          if scope.contains(
            collection: entry.mutation.collection, workspaceID: entry.mutation.workspaceId)
          {
            entry.needsReconciliation = true
            try db.execute(
              sql: "UPDATE outbox SET payload=? WHERE identity=? AND mutation_id=?",
              arguments: [try Self.encoded(entry), i, entry.mutation.mutationId])
          }
        }
      }
      try Self.saveFeed(db, i, s, .init())
      return true
    }
  }
  static func insertEntry(_ db: Database, _ identity: String, _ entry: OutboxEntry) throws {
    let m = entry.mutation
    guard !m.mutationId.isEmpty, !m.collection.isEmpty, !m.recordId.isEmpty,
      !entry.deliveryClientID.isEmpty, ["upsert", "delete"].contains(m.op)
    else { throw SyncStoreError.invalidChange }
    if let version = m.baseVersion { try SyncVersions.validate(version) }
    if let old = try Data.fetchOne(
      db, sql: "SELECT payload FROM outbox WHERE identity=? AND mutation_id=?",
      arguments: [identity, m.mutationId])
    {
      let existing: OutboxEntry = try decode(old)
      guard existing.mutation == m, existing.deliveryClientID == entry.deliveryClientID else {
        throw SyncStoreError.mutationIDReused
      }
      return
    }
    if try Bool.fetchOne(
      db, sql: "SELECT EXISTS(SELECT 1 FROM issues WHERE identity=? AND mutation_id=?)",
      arguments: [identity, m.mutationId]) == true
    {
      throw SyncStoreError.mutationIDReused
    }
    try db.execute(
      sql: "INSERT INTO outbox(identity,mutation_id,payload) VALUES(?,?,?)",
      arguments: [identity, m.mutationId, try encoded(entry)])
  }
  public func addOutbox(identity: AccountIdentity, entries: [OutboxEntry]) async throws {
    let i = try Self.key(identity)
    try await database.write { db in
      for entry in entries { try Self.insertEntry(db, i, entry) }
      try Self.touchReplica(db, i)
    }
  }
  public func outbox(identity: AccountIdentity) async throws -> [OutboxEntry] {
    let i = try Self.key(identity)
    return try await database.read { db in
      try Data.fetchAll(
        db, sql: "SELECT payload FROM outbox WHERE identity=? ORDER BY ordinal", arguments: [i]
      ).map(Self.decode)
    }
  }
  public func replaceRecordMutation(identity: AccountIdentity, entry: OutboxEntry) async throws {
    let i = try Self.key(identity)
    try await database.write { db in
      for data in try Data.fetchAll(
        db, sql: "SELECT payload FROM outbox WHERE identity=?", arguments: [i])
      {
        let old: OutboxEntry = try Self.decode(data)
        if old.mutation.collection == entry.mutation.collection,
          old.mutation.recordId == entry.mutation.recordId
        {
          try Self.requireUnmanaged(db, i, old.mutation.mutationId)
          guard !old.attempted else { throw SyncStoreError.mutationAlreadyAttempted }
          try db.execute(
            sql: "DELETE FROM outbox WHERE identity=? AND mutation_id=?",
            arguments: [i, old.mutation.mutationId])
        }
      }
      try Self.insertEntry(db, i, entry)
      try Self.touchReplica(db, i)
    }
  }
  public func preparePush(identity: AccountIdentity, mutationIDs: [String]) async throws
    -> [OutboxEntry]
  {
    let i = try Self.key(identity)
    return try await database.write { db in
      var result: [OutboxEntry] = []
      for id in mutationIDs {
        guard
          let data = try Data.fetchOne(
            db, sql: "SELECT payload FROM outbox WHERE identity=? AND mutation_id=?",
            arguments: [i, id])
        else { continue }
        var entry: OutboxEntry = try Self.decode(data)
        guard !entry.needsReconciliation else { continue }
        guard try Self.prepareReplicaEntry(db, i, entry: &entry) else { continue }
        entry.attempted = true
        try db.execute(
          sql: "UPDATE outbox SET payload=? WHERE identity=? AND mutation_id=?",
          arguments: [try Self.encoded(entry), i, id])
        result.append(entry)
      }
      try Self.touchReplica(db, i)
      return result
    }
  }
  public func settlePush(identity: AccountIdentity, sent: [OutboxEntry], results: [SyncPushResult])
    async throws
  {
    let i = try Self.key(identity)
    guard Set(results.map(\.mutationId)).count == results.count else {
      throw SyncStoreError.invalidSettlement
    }
    try await database.write { db in
      for result in results {
        guard let entry = sent.first(where: { $0.mutation.mutationId == result.mutationId }),
          entry.mutation.collection == result.collection,
          entry.mutation.recordId == result.recordId,
          ["applied", "conflict", "rejected"].contains(result.status)
        else { throw SyncStoreError.invalidSettlement }
        if result.status == "applied" {
          guard let version = result.version else { throw SyncStoreError.invalidSettlement }
          try SyncVersions.validate(version)
        }
        if result.status == "conflict", (result.conflictId ?? "").isEmpty {
          throw SyncStoreError.invalidSettlement
        }
        guard
          let data = try Data.fetchOne(
            db, sql: "SELECT payload FROM outbox WHERE identity=? AND mutation_id=?",
            arguments: [i, result.mutationId])
        else { continue }
        let existing: OutboxEntry = try Self.decode(data)
        guard existing.mutation == entry.mutation,
          existing.deliveryClientID == entry.deliveryClientID
        else { throw SyncStoreError.mutationIDReused }
        try Self.settleReplicaEntry(db, i, entry: existing, result: result)
        if result.status != "applied" {
          try db.execute(
            sql: "INSERT INTO issues VALUES(?,?,?) ON CONFLICT(identity,mutation_id) DO NOTHING",
            arguments: [
              i, result.mutationId, try Self.encoded(SyncIssue(entry: existing, result: result)),
            ])
        }
        try db.execute(
          sql: "DELETE FROM outbox WHERE identity=? AND mutation_id=?",
          arguments: [i, result.mutationId])
      }
      try Self.touchReplica(db, i)
    }
  }
  public func removeOutbox(identity: AccountIdentity, mutationIDs: [String]) async throws {
    let i = try Self.key(identity)
    try await database.write { db in
      for id in mutationIDs {
        try Self.requireUnmanaged(db, i, id)
        try db.execute(
          sql: "DELETE FROM outbox WHERE identity=? AND mutation_id=?", arguments: [i, id])
      }
      try Self.touchReplica(db, i)
    }
  }
  public func issues(identity: AccountIdentity) async throws -> [SyncIssue] {
    let i = try Self.key(identity)
    return try await database.read { db in
      try Data.fetchAll(
        db, sql: "SELECT payload FROM issues WHERE identity=? ORDER BY mutation_id", arguments: [i]
      ).map(Self.decode)
    }
  }
  public func removeIssues(identity: AccountIdentity, mutationIDs: [String]) async throws {
    let i = try Self.key(identity)
    try await database.write { db in
      for id in mutationIDs {
        try Self.requireUnmanaged(db, i, id)
        try db.execute(
          sql: "DELETE FROM issues WHERE identity=? AND mutation_id=?", arguments: [i, id])
      }
      try Self.touchReplica(db, i)
    }
  }
  public func resolveIssue(identity: AccountIdentity, mutationID: String, replacement: OutboxEntry)
    async throws
  {
    let i = try Self.key(identity)
    guard replacement.mutation.mutationId != mutationID else {
      throw SyncStoreError.mutationIDReused
    }
    try await database.write { db in
      guard
        let data = try Data.fetchOne(
          db, sql: "SELECT payload FROM issues WHERE identity=? AND mutation_id=?",
          arguments: [i, mutationID])
      else { throw SyncStoreError.issueNotFound }
      try Self.requireUnmanaged(db, i, mutationID)
      let issue: SyncIssue = try Self.decode(data)
      guard issue.entry.mutation.collection == replacement.mutation.collection,
        issue.entry.mutation.recordId == replacement.mutation.recordId,
        issue.entry.mutation.workspaceId == replacement.mutation.workspaceId
      else { throw SyncStoreError.invalidSettlement }
      try Self.insertEntry(db, i, replacement)
      try db.execute(
        sql: "DELETE FROM issues WHERE identity=? AND mutation_id=?", arguments: [i, mutationID])
      try Self.touchReplica(db, i)
    }
  }
  public func records(identity: AccountIdentity, collection: String) async throws -> [SyncRecord] {
    let i = try Self.key(identity)
    return try await database.read { db in
      try Data.fetchAll(
        db, sql: "SELECT payload FROM records WHERE identity=? AND collection=? ORDER BY record_id",
        arguments: [i, collection]
      ).map(Self.decode)
    }
  }
  public func record(identity: AccountIdentity, collection: String, id: String) async throws
    -> SyncRecord?
  {
    let i = try Self.key(identity)
    return try await database.read { db in
      try Data.fetchOne(
        db, sql: "SELECT payload FROM records WHERE identity=? AND collection=? AND record_id=?",
        arguments: [i, collection, id]
      ).map(Self.decode)
    }
  }
}
