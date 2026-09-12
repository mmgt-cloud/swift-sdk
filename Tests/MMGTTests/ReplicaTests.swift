import Foundation
import GRDB
import MMGTCore
import MMGTSync
import MMGTSyncSQLite
import Testing

@Suite(.timeLimit(.minutes(1))) struct ReplicaTests {
  let helper = SyncStoreTests()
  func identity(
    _ principal: ReplicaPrincipal = .guest("local-a"), host: String = "stage.example.invalid",
    app: String = "app-a"
  ) throws -> ReplicaIdentity {
    try .init(
      configuration: .init(baseURL: URL(string: "https://\(host)/sync")!, appID: app),
      principal: principal)
  }
  func replica(_ store: SQLiteSyncStore, _ identity: ReplicaIdentity? = nil) throws -> LocalReplica
  {
    try .init(identity: identity ?? self.identity(), collections: ["notes", "lists"], store: store)
  }
  func intent(_ id: String = "n", text: String = "offline", collection: String = "notes")
    -> ReplicaIntent
  {
    .init(key: .init(collection: collection, id: id), data: ["text": .string(text)], deleted: false)
  }
  func applied(_ entry: OutboxEntry, _ version: String) -> SyncPushResult {
    .init(
      mutationId: entry.mutation.mutationId, collection: entry.mutation.collection,
      recordId: entry.mutation.recordId, status: "applied", version: version)
  }
  func rejected(_ entry: OutboxEntry) -> SyncPushResult {
    .init(
      mutationId: entry.mutation.mutationId, collection: entry.mutation.collection,
      recordId: entry.mutation.recordId, status: "rejected", error: "schema_validation_failed")
  }
  func response<T: Encodable>(_ value: T) throws -> HTTPResponse {
    .init(data: try JSONEncoder().encode(value), status: 200)
  }
  func bootstrap(_ user: String = "user-a") -> SyncBootstrapResponse {
    .init(
      collections: ["notes", "lists"].map {
        .init(
          key: $0, displayName: $0, mode: "managed", accessScope: "user",
          conflictPolicy: "reject_stale",
          schema: [:], enabled: true, createdAt: "2026-09-12T00:00:00Z",
          updatedAt: "2026-09-12T00:00:00Z")
      }, contractRevision: "2026-09-05", serverTime: "2026-09-12T00:00:00Z", appID: "app-a",
      userID: user)
  }
  func snapshotResponse(_ changes: [SyncChange] = [], version: String = "5") -> SyncSnapshotResponse
  {
    .init(
      records: changes, watermark: version, cursor: "snapshot-\(version)", hasMore: false,
      expiresAt: "2030-01-01T00:00:00Z")
  }
  func prepared(_ store: SQLiteSyncStore, source: ReplicaIdentity, target: ReplicaIdentity)
    async throws -> ReplicaImportPlan
  {
    let a = try await store.replicaSnapshot(identity: source)
    let b = try await store.replicaSnapshot(identity: target)
    return try await store.prepareReplicaImport(
      .init(
        source: source, target: target,
        sourceRevision: a.metadata.revision, targetRevision: b.metadata.revision, items: [],
        requiresConfirmation: false))
  }

  @Test func offlineCRUDTransactionsRestartAndExplicitIdentityIsolation() async throws {
    let file = helper.path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = try SQLiteSyncStore(fileURL: file)
    let guest = try identity()
    let local = try replica(store)
    try await local.transaction { tx in
      try tx.upsert(collection: "lists", id: "list", data: ["title": "Personal"])
      try tx.upsert(collection: "notes", id: "n", data: ["text": "one"])
      #expect(tx.get(collection: "notes", id: "n")?.data?["text"] == "one")
      try tx.upsert(collection: "notes", id: "n", data: ["text": "two"])
      #expect(tx.list(collection: "notes").count == 1)
    }
    let initial = try await local.snapshot()
    #expect(initial.metadata.journal.count == 2 && initial.outbox.isEmpty)
    #expect(
      initial.records.allSatisfy {
        $0.serverVersion == nil && $0.localRevision != nil && $0.pending
      })
    await local.close()
    let reopened = try SQLiteSyncStore(fileURL: file)
    let restored = try replica(reopened)
    #expect(try await restored.get(collection: "notes", id: "n")?.data?["text"] == "two")
    #expect(try await restored.snapshot().metadata.journal == initial.metadata.journal)
    for other in [
      try identity(.user("local-a")), try identity(.guest("local-b")),
      try identity(host: "prod.example.invalid"), try identity(app: "app-b"),
    ] {
      #expect(try await reopened.replicaSnapshot(identity: other).records.isEmpty)
    }
    let equivalent = try ReplicaIdentity(
      configuration: .init(
        baseURL: URL(string: "https://STAGE.example.invalid:443/sync/")!, appID: "app-a"),
      principal: guest.principal)
    #expect(try await reopened.replicaSnapshot(identity: equivalent).records.count == 2)
    try await restored.delete(collection: "notes", id: "n")
    #expect(try await restored.list(collection: "notes").isEmpty)
    #expect(try await restored.snapshot().metadata.journal.count == 3)
  }
  @Test func callbackFailureAndRealSQLFailureRollbackAllRecordsAndJournal() async throws {
    let file = helper.path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = try SQLiteSyncStore(fileURL: file)
    let user = try identity(.user("user-a"))
    let local = try replica(store, user)
    let before = try await local.snapshot()
    await #expect(throws: ReplicaError.invalidRecord) {
      try await local.transaction { tx in
        try tx.upsert(collection: "notes", id: "valid", data: ["text": "safe"])
        throw ReplicaError.invalidRecord
      }
    }
    #expect(try await local.snapshot() == before)
    let fault = try DatabaseQueue(path: file.path)
    try await fault.write { db in
      try db.execute(
        sql:
          "CREATE TRIGGER fail_queue BEFORE INSERT ON outbox WHEN (SELECT COUNT(*) FROM outbox)>0 BEGIN SELECT RAISE(ABORT,'test disk failure'); END"
      )
    }
    await #expect(throws: (any Error).self) {
      try await local.transaction { tx in
        try tx.upsert(collection: "notes", id: "one", data: [:])
        try tx.upsert(collection: "notes", id: "two", data: [:])
      }
    }
    #expect(try await local.snapshot() == before)
    #expect(try await store.outbox(identity: user.account!).isEmpty)
  }
  @Test func concurrentConnectionsUseCASAndObservationSeesExternalCommits() async throws {
    let file = helper.path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let a = try SQLiteSyncStore(fileURL: file)
    let b = try SQLiteSyncStore(fileURL: file)
    let guest = try identity()
    let local = try replica(a)
    var iterator = await local.changes().makeAsyncIterator()
    let first = try #require(await iterator.next())
    let writes = await withTaskGroup(of: Bool.self) { group in
      for (index, store) in [a, b].enumerated() {
        group.addTask {
          do {
            try await store.commitReplica(
              identity: guest, expectedRevision: first.metadata.revision,
              intents: [intent(String(index))])
            return true
          } catch { return false }
        }
      }
      var results: [Bool] = []
      for await result in group { results.append(result) }
      return results
    }
    #expect(writes.filter { $0 }.count == 1)
    let changed = try #require(await iterator.next())
    #expect(changed.records.count == 1 && changed.metadata.revision != first.metadata.revision)
    await local.close()
    await #expect(throws: ReplicaError.closed) {
      try await local.upsert(collection: "notes", id: "late", data: [:])
    }
  }
  @Test func CASChainsAwaitAcknowledgementAndUncertainWireIsImmutable() async throws {
    let file = helper.path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = try SQLiteSyncStore(fileURL: file)
    let user = try identity(.user("user-a"))
    let local = try replica(store, user)
    try await local.upsert(collection: "notes", id: "n", data: ["text": "one"])
    try await local.upsert(collection: "notes", id: "n", data: ["text": "two"])
    let queued = try await store.outbox(identity: user.account!)
    let ids = queued.map(\.mutation.mutationId)
    let first = try await store.preparePush(identity: user.account!, mutationIDs: ids)
    #expect(first.count == 1 && first[0].mutation.baseVersion == "0")
    let reopened = try SQLiteSyncStore(fileURL: file)
    #expect(try await reopened.preparePush(identity: user.account!, mutationIDs: ids) == first)
    try await reopened.settlePush(
      identity: user.account!, sent: first, results: [applied(first[0], "9007199254740993")])
    let second = try await reopened.preparePush(identity: user.account!, mutationIDs: ids)
    #expect(second.count == 1 && second[0].mutation.baseVersion == "9007199254740993")
    #expect(
      second[0].mutation.mutationId == ids[1]
        && second[0].deliveryClientID == first[0].deliveryClientID)
    try await reopened.settlePush(
      identity: user.account!, sent: second, results: [applied(second[0], "9007199254740994")])
    let final = try await local.snapshot()
    #expect(final.outbox.isEmpty && final.records.first?.data?["text"] == "two")
    #expect(
      final.records.first?.serverVersion == "9007199254740994"
        && final.records.first?.localRevision == "2")
    #expect(final.records.first?.pending == false)
  }
  @Test func RejectionKeepsMaterializedEditsAndExplicitResolutionReplacesWholeChain() async throws {
    let file = helper.path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = try SQLiteSyncStore(fileURL: file)
    let user = try identity(.user("user-a"))
    let local = try replica(store, user)
    try await local.upsert(collection: "notes", id: "n", data: ["text": "first"])
    try await local.upsert(collection: "notes", id: "n", data: ["text": "later"])
    let ids = try await store.outbox(identity: user.account!).map(\.mutation.mutationId)
    let sent = try await store.preparePush(identity: user.account!, mutationIDs: ids)
    try await store.settlePush(identity: user.account!, sent: sent, results: [rejected(sent[0])])
    #expect(try await store.preparePush(identity: user.account!, mutationIDs: ids).isEmpty)
    let state = try await local.snapshot()
    #expect(state.records.first?.data?["text"] == "later" && state.records.first?.issues.count == 2)
    #expect(state.outbox.first?.needsReconciliation == true)
    await #expect(throws: ReplicaError.useReplicaResolution) {
      try await store.removeIssues(identity: user.account!, mutationIDs: [ids[0]])
    }
    try await local.resolveIssue(ids[0], replacement: intent(text: "reviewed"))
    let replacement = try await store.outbox(identity: user.account!)
    #expect(replacement.count == 1 && !ids.contains(replacement[0].mutation.mutationId))
    #expect(
      try await local.snapshot().metadata.journal.filter { $0.state == "resolved" }.count == 2)
    let retry = try await store.preparePush(
      identity: user.account!, mutationIDs: replacement.map(\.mutation.mutationId))
    #expect(retry.count == 1 && retry[0].mutation.baseVersion == "0")
  }
  @Test func SnapshotRecoveryRetainsQueueAndRejectsDelayedAppliedStateBelowFloor() async throws {
    let file = helper.path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = try SQLiteSyncStore(fileURL: file)
    let user = try identity(.user("user-a"))
    let local = try replica(store, user)
    let scope = try SyncScope(collections: ["notes"])
    try await local.upsert(collection: "notes", id: "n", data: ["text": "uncertain"])
    let ids = try await store.outbox(identity: user.account!).map(\.mutation.mutationId)
    let sent = try await store.preparePush(identity: user.account!, mutationIDs: ids)
    try await helper.seed(store, user.account!, scope, [], watermark: "20")
    try await store.settlePush(
      identity: user.account!, sent: sent, results: [applied(sent[0], "19")])
    #expect(try await local.get(collection: "notes", id: "n") == nil)
    try await local.upsert(collection: "notes", id: "new", data: ["text": "pending"])
    let feed = try await store.feed(identity: user.account!, scope: scope)
    #expect(
      try await store.resetFeed(
        identity: user.account!, scope: scope, expectedRevision: feed.revision, reconcile: true))
    #expect(try await local.get(collection: "notes", id: "new")?.data?["text"] == "pending")
    #expect(
      try await local.get(collection: "notes", id: "new")?.issues.first?.result.error
        == "requires_reconciliation")
  }
  @Test func LegacyAccountQueueKeepsIDsAndNoGuestCanClaimIt() async throws {
    let file = helper.path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = try SQLiteSyncStore(fileURL: file)
    let user = try identity(.user("user-a"))
    let original = helper.entry(attempted: true)
    try await store.addOutbox(identity: user.account!, entries: [original])
    let adopted = try await store.replicaSnapshot(identity: user)
    #expect(adopted.metadata.journal.first?.entry == original)
    #expect(adopted.outbox == [original])
    #expect(try await store.replicaSnapshot(identity: identity(.guest("user-a"))).records.isEmpty)
    #expect(
      try await store.preparePush(
        identity: user.account!, mutationIDs: [original.mutation.mutationId]) == [original])
    await #expect(throws: ReplicaError.useReplicaResolution) {
      try await store.removeOutbox(
        identity: user.account!, mutationIDs: [original.mutation.mutationId])
    }
  }
  @Test func GuestCannotConnectAndOrdinaryBootstrapMustConfirmExactAccount() async throws {
    let file = helper.path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = try SQLiteSyncStore(fileURL: file)
    let guest = try replica(store)
    let transport = RecordingTransport([try response(bootstrap("foreign"))])
    await #expect(throws: ReplicaError.guestCannotSync) {
      try await guest.connect(tokenProvider: { "guest" }, transport: transport)
    }
    #expect(await transport.requests.isEmpty)
    let user = try replica(store, identity(.user("user-a")))
    await #expect(throws: ReplicaError.identityMismatch) {
      try await user.connect(tokenProvider: { "jwt" }, transport: transport)
    }
    #expect(await transport.requests.first?.value(forHTTPHeaderField: "X-Sync-User-ID") == "user-a")
  }
  @Test func ImportFreshSnapshotDoesNotPushExistingQueueAndConsentIsMandatory() async throws {
    let file = helper.path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = try SQLiteSyncStore(fileURL: file)
    let guest = try replica(store)
    let user = try replica(store, identity(.user("user-a")))
    try await guest.upsert(collection: "notes", id: "guest", data: ["text": "source"])
    try await user.upsert(collection: "notes", id: "pending", data: ["text": "account draft"])
    let transport = RecordingTransport(
      try [response(bootstrap()), response(bootstrap()), response(snapshotResponse())])
    try await user.connect(tokenProvider: { "jwt" }, transport: transport)
    let plan = try await guest.prepareImport(to: user)
    #expect(plan.requiresConfirmation && plan.items.count == 1)
    #expect(
      await transport.requests.map(\.url!.lastPathComponent) == [
        "bootstrap", "bootstrap", "snapshot",
      ])
    await #expect(throws: ReplicaError.confirmationRequired) {
      try await guest.approveImport(plan.id, to: user)
    }
    #expect(try await guest.snapshot().metadata.adoptedImportID == nil)
    let committed = try await guest.approveImport(plan.id, to: user, confirmed: true)
    #expect(committed.committed && committed.mutationIDs.count == 1)
    #expect(try await user.list(collection: "notes").count == 2)
    #expect(try await user.snapshot().outbox.allSatisfy { !$0.needsReconciliation })
    #expect(try await guest.approveImport(plan.id, to: user) == committed)
  }
  @Test func AtomicImportRetainsOnlyCopyAndOneAccountAcrossRestartAndPartialCommit() async throws {
    let file = helper.path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = try SQLiteSyncStore(fileURL: file)
    let source = try identity()
    let target = try identity(.user("user-a"))
    let local = try replica(store)
    try await local.transaction { tx in
      try tx.upsert(collection: "lists", id: "l", data: ["name": "list"])
      try tx.upsert(collection: "notes", id: "n", data: ["text": "note"])
    }
    let plan = try await prepared(store, source: source, target: target)
    let committed = try await store.commitReplicaImport(
      id: plan.id, source: source, confirmed: false, decisions: [])
    let reopened = try SQLiteSyncStore(fileURL: file)
    #expect(
      try await reopened.commitReplicaImport(
        id: plan.id, source: source, confirmed: false, decisions: []) == committed)
    #expect(try await reopened.replicaSnapshot(identity: source).records.count == 2)
    let queue = try await reopened.preparePush(
      identity: target.account!, mutationIDs: committed.mutationIDs)
    try await reopened.settlePush(
      identity: target.account!, sent: queue, results: [applied(queue[0], "10")])
    let retry = try await SQLiteSyncStore(fileURL: file).preparePush(
      identity: target.account!, mutationIDs: committed.mutationIDs)
    #expect(retry == [queue[1]])
    let progress = try await local.importProgress(plan.id)
    #expect(progress.applied == 1 && progress.pending == 1)
    await #expect(throws: ReplicaError.alreadyAdopted) {
      try await local.upsert(collection: "notes", id: "late", data: [:])
    }
    await #expect(throws: ReplicaError.alreadyAdopted) {
      _ = try await prepared(store, source: source, target: identity(.user("user-b")))
    }
  }
  @Test func ImportCollisionAndTargetChangeRequireNewExplicitDecision() async throws {
    let file = helper.path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = try SQLiteSyncStore(fileURL: file)
    let source = try identity()
    let target = try identity(.user("user-a"))
    let local = try replica(store)
    try await local.upsert(collection: "notes", id: "note-a", data: ["text": "guest"])
    try await helper.seed(
      store, target.account!, SyncScope(collections: ["notes"]), [helper.change("4")],
      watermark: "4")
    let plan = try await prepared(store, source: source, target: target)
    #expect(plan.items.first?.target?.serverVersion == "4")
    await #expect(throws: ReplicaError.collision) {
      _ = try await store.commitReplicaImport(
        id: plan.id, source: source, confirmed: true, decisions: [])
    }
    let key = ReplicaRecordKey(collection: "notes", id: "note-a")
    let done = try await store.commitReplicaImport(
      id: plan.id, source: source, confirmed: true,
      decisions: [.init(key: key, action: .replaceTarget)])
    #expect(try await store.outbox(identity: target.account!).first?.mutation.baseVersion == "4")
    #expect(done.committed)
    let otherGuest = try identity(.guest("other"))
    let otherReplica = try replica(store, otherGuest)
    try await otherReplica.upsert(collection: "notes", id: "different", data: [:])
    let stale = try await prepared(store, source: otherGuest, target: target)
    try await replica(store, target).upsert(collection: "notes", id: "change", data: [:])
    await #expect(throws: ReplicaError.importChanged) {
      _ = try await store.commitReplicaImport(
        id: stale.id, source: otherGuest, confirmed: true, decisions: [])
    }
  }
  @Test func ImportDependencyCycleAndSQLFailureRollbackSourceTargetAndPlan() async throws {
    let file = helper.path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = try SQLiteSyncStore(fileURL: file)
    let source = try identity()
    let target = try identity(.user("user-a"))
    let local = try replica(store)
    try await local.transaction { tx in
      try tx.upsert(collection: "notes", id: "a", data: [:])
      try tx.upsert(collection: "notes", id: "b", data: [:])
    }
    let plan = try await prepared(store, source: source, target: target)
    let a = ReplicaRecordKey(collection: "notes", id: "a")
    let b = ReplicaRecordKey(collection: "notes", id: "b")
    await #expect(throws: ReplicaError.dependencyCycle) {
      _ = try await store.commitReplicaImport(
        id: plan.id, source: source, confirmed: false,
        decisions: [
          .init(key: a, action: .importRecord, dependencies: [b]),
          .init(key: b, action: .importRecord, dependencies: [a]),
        ])
    }
    #expect(try await store.replicaSnapshot(identity: target).outbox.isEmpty)
    let fault = try DatabaseQueue(path: file.path)
    try await fault.write { db in
      try db.execute(
        sql:
          "CREATE TRIGGER fail_import BEFORE UPDATE ON replica_imports BEGIN SELECT RAISE(ABORT,'test failure at import commit'); END"
      )
    }
    await #expect(throws: (any Error).self) {
      _ = try await store.commitReplicaImport(
        id: plan.id, source: source, confirmed: false, decisions: [])
    }
    #expect(try await store.replicaSnapshot(identity: target).outbox.isEmpty)
    #expect(try await store.replicaSnapshot(identity: source).metadata.adoptedImportID == nil)
    #expect(try await store.replicaImport(id: plan.id, source: source).committed == false)
  }
  @Test func ImportedDependenciesWaitForConfirmedParentAndFailureStopsChild() async throws {
    let file = helper.path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = try SQLiteSyncStore(fileURL: file)
    let source = try identity()
    let target = try identity(.user("user-a"))
    let local = try replica(store)
    try await local.transaction { tx in
      try tx.upsert(collection: "lists", id: "l", data: [:])
      try tx.upsert(collection: "notes", id: "n", data: [:])
    }
    let plan = try await prepared(store, source: source, target: target)
    let committed = try await store.commitReplicaImport(
      id: plan.id, source: source, confirmed: false,
      decisions: [
        .init(
          key: .init(collection: "notes", id: "n"), action: .importRecord,
          dependencies: [.init(collection: "lists", id: "l")])
      ])
    let parent = try await store.preparePush(
      identity: target.account!, mutationIDs: committed.mutationIDs)
    #expect(parent.count == 1 && parent[0].mutation.collection == "lists")
    try await store.settlePush(
      identity: target.account!, sent: parent, results: [rejected(parent[0])])
    #expect(
      try await store.preparePush(identity: target.account!, mutationIDs: committed.mutationIDs)
        .isEmpty)
    #expect(try await store.outbox(identity: target.account!).first?.needsReconciliation == true)
  }
  @Test func PublicImportValidatesPersistedDataAndClosedTargetCannotCommit() async throws {
    let file = helper.path()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = try SQLiteSyncStore(fileURL: file)
    let source = try identity()
    let target = try identity(.user("user-a"))
    let local = try replica(store)
    try await local.upsert(collection: "notes", id: "n", data: ["text": "not accepted"])
    let plan = try await prepared(store, source: source, target: target)
    let strict = try LocalReplica(identity: target, collections: ["notes", "lists"], store: store) {
      value in
      guard value.data?["text"] == "accepted" else { throw ReplicaError.invalidRecord }
    }
    await #expect(throws: ReplicaError.invalidRecord) {
      _ = try await local.approveImport(plan.id, to: strict)
    }
    #expect(try await store.replicaSnapshot(identity: source).metadata.adoptedImportID == nil)
    await strict.close()
    await #expect(throws: ReplicaError.closed) {
      _ = try await local.approveImport(
        plan.id, to: strict,
        decisions: [
          .init(
            key: .init(collection: "notes", id: "n"), action: .importRecord,
            data: ["text": "accepted"])
        ])
    }
  }
}
