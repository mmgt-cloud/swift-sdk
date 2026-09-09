import Foundation
import CryptoKit
import GRDB
import MMGTCore
import MMGTSync

/// A WAL database with transactionally fenced feeds, staged snapshots and a durable per-account outbox.
public final class SQLiteSyncStore: SyncLocalStore, Sendable {
    private let database: DatabasePool
    public init(fileURL: URL) throws {
        guard fileURL.isFileURL else { throw MMGTError.invalidConfiguration("SQLite requires a local file URL") }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.busyMode = .timeout(5)
        database = try DatabasePool(path: fileURL.path, configuration: config)
        var migrations = DatabaseMigrator()
        migrations.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE feeds (identity TEXT NOT NULL, scope TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(identity, scope));
                CREATE TABLE records (identity TEXT NOT NULL, collection TEXT NOT NULL, record_id TEXT NOT NULL, workspace TEXT NOT NULL, version TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(identity, collection, record_id));
                CREATE TABLE snapshot_records (identity TEXT NOT NULL, scope TEXT NOT NULL, collection TEXT NOT NULL, record_id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(identity, scope, collection, record_id));
                CREATE TABLE outbox (ordinal INTEGER PRIMARY KEY AUTOINCREMENT, identity TEXT NOT NULL, mutation_id TEXT NOT NULL, payload BLOB NOT NULL, UNIQUE(identity, mutation_id));
                CREATE TABLE issues (identity TEXT NOT NULL, mutation_id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(identity, mutation_id));
                """)
        }
        try migrations.migrate(database)
        var resourceURL = fileURL
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try resourceURL.setResourceValues(values)
    }
    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private static func key<T: Encodable>(_ value: T) throws -> String {
        SHA256.hash(data: try encoded(value)).map { String(format:"%02x", $0) }.joined()
    }
    private static func decode<T: Decodable>(_ data: Data) throws -> T { try JSONDecoder().decode(T.self, from: data) }
    private static func loadFeed(_ db: Database, _ identity: String, _ scope: String) throws -> SyncFeedState {
        guard let data = try Data.fetchOne(db, sql:"SELECT payload FROM feeds WHERE identity=? AND scope=?", arguments:[identity,scope]) else { return .init() }
        return try decode(data)
    }
    private static func saveFeed(_ db: Database, _ identity: String, _ scope: String, _ state: SyncFeedState) throws {
        var state = state; state.revision = UUID().uuidString
        try db.execute(sql:"INSERT INTO feeds VALUES(?,?,?) ON CONFLICT(identity,scope) DO UPDATE SET payload=excluded.payload", arguments:[identity,scope,try encoded(state)])
    }
    public func feed(identity: AccountIdentity, scope: SyncScope) async throws -> SyncFeedState {
        let i = try Self.key(identity), s = try Self.key(scope)
        return try await database.read { try Self.loadFeed($0,i,s) }
    }
    private static func saveRecord(_ db: Database, _ identity: String, _ change: SyncChange) throws {
        if let old = try String.fetchOne(db,sql:"SELECT version FROM records WHERE identity=? AND collection=? AND record_id=?",arguments:[identity,change.collection,change.recordId]), !(try SyncVersions.less(old, than:change.version)) { return }
        let value = SyncRecord(collection:change.collection,id:change.recordId,version:change.version,data:change.data,deleted:change.op == "delete",workspaceId:change.workspaceId,updatedAt:change.createdAt)
        try db.execute(sql:"INSERT INTO records VALUES(?,?,?,?,?,?) ON CONFLICT(identity,collection,record_id) DO UPDATE SET workspace=excluded.workspace,version=excluded.version,payload=excluded.payload",arguments:[identity,change.collection,change.recordId,change.workspaceId ?? "",change.version,try encoded(value)])
    }
    public func commitPage(identity: AccountIdentity, scope: SyncScope, expectedRevision: String, page: SyncPullResponse) async throws -> Bool {
        let i = try Self.key(identity), s = try Self.key(scope)
        for change in page.changes { try validateSyncChange(change,identity:identity,scope:scope) }
        guard !page.nextCursor.isEmpty else { throw SyncStoreError.invalidChange }
        return try await database.write { db in
            let state = try Self.loadFeed(db,i,s)
            guard state.revision == expectedRevision, state.cursor != nil else { return false }
            for change in page.changes { try Self.saveRecord(db,i,change) }
            try Self.saveFeed(db,i,s,.init(cursor:page.nextCursor))
            return true
        }
    }
    public func commitSnapshotPage(identity: AccountIdentity, scope: SyncScope, expectedRevision: String, page: SyncSnapshotResponse) async throws -> Bool {
        let i = try Self.key(identity), s = try Self.key(scope)
        try SyncVersions.validate(page.watermark)
        for change in page.records {
            try validateSyncChange(change,identity:identity,scope:scope)
            guard !(try SyncVersions.less(page.watermark,than:change.version)) else { throw SyncStoreError.invalidChange }
        }
        guard page.hasMore ? !(page.nextPage ?? "").isEmpty : !(page.cursor ?? "").isEmpty else { throw SyncStoreError.invalidChange }
        return try await database.write { db in
            let state = try Self.loadFeed(db,i,s)
            guard state.revision == expectedRevision, state.cursor == nil else { return false }
            if let progress = state.snapshot, progress.watermark != page.watermark || progress.expiresAt != page.expiresAt { throw SyncStoreError.invalidChange }
            for change in page.records {
                try db.execute(sql:"INSERT INTO snapshot_records VALUES(?,?,?,?,?) ON CONFLICT(identity,scope,collection,record_id) DO UPDATE SET payload=excluded.payload",arguments:[i,s,change.collection,change.recordId,try Self.encoded(change)])
            }
            if page.hasMore {
                try Self.saveFeed(db,i,s,.init(snapshot:.init(nextPage:page.nextPage!,watermark:page.watermark,expiresAt:page.expiresAt)))
            } else {
                // Other scopes may have fetched records newer than this snapshot. Preserve those.
                for row in try Row.fetchAll(db,sql:"SELECT collection,record_id,workspace,version FROM records WHERE identity=?",arguments:[i]) {
                    let collection:String=row["collection"], id:String=row["record_id"], workspace:String=row["workspace"], version:String=row["version"]
                    if scope.contains(collection:collection,workspaceID:workspace), !(try SyncVersions.less(page.watermark,than:version)) {
                        try db.execute(sql:"DELETE FROM records WHERE identity=? AND collection=? AND record_id=?",arguments:[i,collection,id])
                    }
                }
                for data in try Data.fetchAll(db,sql:"SELECT payload FROM snapshot_records WHERE identity=? AND scope=?",arguments:[i,s]) {
                    let change:SyncChange = try Self.decode(data)
                    try Self.saveRecord(db,i,change)
                }
                try db.execute(sql:"DELETE FROM snapshot_records WHERE identity=? AND scope=?",arguments:[i,s])
                try Self.saveFeed(db,i,s,.init(cursor:page.cursor))
            }
            return true
        }
    }
    public func resetFeed(identity: AccountIdentity, scope: SyncScope, expectedRevision: String, reconcile: Bool) async throws -> Bool {
        let i = try Self.key(identity), s = try Self.key(scope)
        return try await database.write { db in
            guard try Self.loadFeed(db,i,s).revision == expectedRevision else { return false }
            try db.execute(sql:"DELETE FROM snapshot_records WHERE identity=? AND scope=?",arguments:[i,s])
            if reconcile {
                for data in try Data.fetchAll(db,sql:"SELECT payload FROM outbox WHERE identity=?",arguments:[i]) {
                    var entry:OutboxEntry = try Self.decode(data)
                    if scope.contains(collection:entry.mutation.collection,workspaceID:entry.mutation.workspaceId) {
                        entry.needsReconciliation = true
                        try db.execute(sql:"UPDATE outbox SET payload=? WHERE identity=? AND mutation_id=?",arguments:[try Self.encoded(entry),i,entry.mutation.mutationId])
                    }
                }
            }
            try Self.saveFeed(db,i,s,.init())
            return true
        }
    }
    private static func insertEntry(_ db: Database, _ identity: String, _ entry: OutboxEntry) throws {
        let m = entry.mutation
        guard !m.mutationId.isEmpty, !m.collection.isEmpty, !m.recordId.isEmpty, !entry.deliveryClientID.isEmpty, ["upsert","delete"].contains(m.op) else { throw SyncStoreError.invalidChange }
        if let version=m.baseVersion { try SyncVersions.validate(version) }
        if let old = try Data.fetchOne(db,sql:"SELECT payload FROM outbox WHERE identity=? AND mutation_id=?",arguments:[identity,m.mutationId]) {
            let existing:OutboxEntry = try decode(old)
            guard existing.mutation == m, existing.deliveryClientID == entry.deliveryClientID else { throw SyncStoreError.mutationIDReused }
            return
        }
        if try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM issues WHERE identity=? AND mutation_id=?)",arguments:[identity,m.mutationId]) == true { throw SyncStoreError.mutationIDReused }
        try db.execute(sql:"INSERT INTO outbox(identity,mutation_id,payload) VALUES(?,?,?)",arguments:[identity,m.mutationId,try encoded(entry)])
    }
    public func addOutbox(identity: AccountIdentity, entries: [OutboxEntry]) async throws {
        let i = try Self.key(identity)
        try await database.write { db in for entry in entries { try Self.insertEntry(db,i,entry) } }
    }
    public func outbox(identity: AccountIdentity) async throws -> [OutboxEntry] {
        let i = try Self.key(identity)
        return try await database.read { db in try Data.fetchAll(db,sql:"SELECT payload FROM outbox WHERE identity=? ORDER BY ordinal",arguments:[i]).map(Self.decode) }
    }
    public func replaceRecordMutation(identity: AccountIdentity, entry: OutboxEntry) async throws {
        let i = try Self.key(identity)
        try await database.write { db in
            for data in try Data.fetchAll(db,sql:"SELECT payload FROM outbox WHERE identity=?",arguments:[i]) {
                let old:OutboxEntry = try Self.decode(data)
                if old.mutation.collection == entry.mutation.collection, old.mutation.recordId == entry.mutation.recordId {
                    guard !old.attempted else { throw SyncStoreError.mutationAlreadyAttempted }
                    try db.execute(sql:"DELETE FROM outbox WHERE identity=? AND mutation_id=?",arguments:[i,old.mutation.mutationId])
                }
            }
            try Self.insertEntry(db,i,entry)
        }
    }
    public func preparePush(identity: AccountIdentity, mutationIDs: [String]) async throws -> [OutboxEntry] {
        let i = try Self.key(identity)
        return try await database.write { db in
            var result:[OutboxEntry]=[]
            for id in mutationIDs {
                guard let data = try Data.fetchOne(db,sql:"SELECT payload FROM outbox WHERE identity=? AND mutation_id=?",arguments:[i,id]) else { continue }
                var entry:OutboxEntry = try Self.decode(data)
                guard !entry.needsReconciliation else { continue }
                entry.attempted = true
                try db.execute(sql:"UPDATE outbox SET payload=? WHERE identity=? AND mutation_id=?",arguments:[try Self.encoded(entry),i,id])
                result.append(entry)
            }
            return result
        }
    }
    public func settlePush(identity: AccountIdentity, sent: [OutboxEntry], results: [SyncPushResult]) async throws {
        let i = try Self.key(identity)
        guard Set(results.map(\.mutationId)).count == results.count else { throw SyncStoreError.invalidSettlement }
        try await database.write { db in
            for result in results {
                guard let entry=sent.first(where:{$0.mutation.mutationId == result.mutationId}), entry.mutation.collection == result.collection, entry.mutation.recordId == result.recordId, ["applied","conflict","rejected"].contains(result.status) else { throw SyncStoreError.invalidSettlement }
                if result.status == "applied" { guard let version=result.version else { throw SyncStoreError.invalidSettlement }; try SyncVersions.validate(version) }
                if result.status == "conflict", (result.conflictId ?? "").isEmpty { throw SyncStoreError.invalidSettlement }
                guard let data = try Data.fetchOne(db,sql:"SELECT payload FROM outbox WHERE identity=? AND mutation_id=?",arguments:[i,result.mutationId]) else { continue }
                let existing:OutboxEntry = try Self.decode(data)
                guard existing.mutation == entry.mutation, existing.deliveryClientID == entry.deliveryClientID else { throw SyncStoreError.mutationIDReused }
                if result.status != "applied" {
                    try db.execute(sql:"INSERT INTO issues VALUES(?,?,?) ON CONFLICT(identity,mutation_id) DO NOTHING",arguments:[i,result.mutationId,try Self.encoded(SyncIssue(entry:existing,result:result))])
                }
                try db.execute(sql:"DELETE FROM outbox WHERE identity=? AND mutation_id=?",arguments:[i,result.mutationId])
            }
        }
    }
    public func removeOutbox(identity: AccountIdentity, mutationIDs: [String]) async throws {
        let i = try Self.key(identity)
        try await database.write { db in for id in mutationIDs { try db.execute(sql:"DELETE FROM outbox WHERE identity=? AND mutation_id=?",arguments:[i,id]) } }
    }
    public func issues(identity: AccountIdentity) async throws -> [SyncIssue] {
        let i = try Self.key(identity)
        return try await database.read { db in try Data.fetchAll(db,sql:"SELECT payload FROM issues WHERE identity=? ORDER BY mutation_id",arguments:[i]).map(Self.decode) }
    }
    public func removeIssues(identity: AccountIdentity, mutationIDs: [String]) async throws {
        let i = try Self.key(identity)
        try await database.write { db in for id in mutationIDs { try db.execute(sql:"DELETE FROM issues WHERE identity=? AND mutation_id=?",arguments:[i,id]) } }
    }
    public func resolveIssue(identity: AccountIdentity, mutationID: String, replacement: OutboxEntry) async throws {
        let i = try Self.key(identity)
        guard replacement.mutation.mutationId != mutationID else { throw SyncStoreError.mutationIDReused }
        try await database.write { db in
            guard let data=try Data.fetchOne(db,sql:"SELECT payload FROM issues WHERE identity=? AND mutation_id=?",arguments:[i,mutationID]) else { throw SyncStoreError.issueNotFound }
            let issue:SyncIssue = try Self.decode(data)
            guard issue.entry.mutation.collection == replacement.mutation.collection, issue.entry.mutation.recordId == replacement.mutation.recordId, issue.entry.mutation.workspaceId == replacement.mutation.workspaceId else { throw SyncStoreError.invalidSettlement }
            try Self.insertEntry(db,i,replacement)
            try db.execute(sql:"DELETE FROM issues WHERE identity=? AND mutation_id=?",arguments:[i,mutationID])
        }
    }
    public func records(identity: AccountIdentity, collection: String) async throws -> [SyncRecord] {
        let i = try Self.key(identity)
        return try await database.read { db in try Data.fetchAll(db,sql:"SELECT payload FROM records WHERE identity=? AND collection=? ORDER BY record_id",arguments:[i,collection]).map(Self.decode) }
    }
    public func record(identity: AccountIdentity, collection: String, id: String) async throws -> SyncRecord? {
        let i = try Self.key(identity)
        return try await database.read { db in try Data.fetchOne(db,sql:"SELECT payload FROM records WHERE identity=? AND collection=? AND record_id=?",arguments:[i,collection,id]).map(Self.decode) }
    }
}
