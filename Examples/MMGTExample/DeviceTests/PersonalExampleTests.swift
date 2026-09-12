import Foundation
import MMGTAI
import MMGTAuth
import MMGTCore
import MMGTSync
import MMGTSyncSQLite
import Testing

@testable import MMGTExample

@Suite(.timeLimit(.minutes(1))) @MainActor struct PersonalExampleTests {
  private func config() throws -> ExampleConfiguration {
    try JSONDecoder().decode(
      ExampleConfiguration.self,
      from: Data(
        #"{"appID":"app-a","authURL":"https://stage.example.invalid/auth","billingURL":"https://stage.example.invalid/billing","syncURL":"https://stage.example.invalid/sync","aiURL":"https://stage.example.invalid/ai","realtimeURL":"https://stage.example.invalid/realtime","oidcClientID":"test","redirectURL":"https://callback.example.invalid/ios","relyingPartyID":"example.invalid","syncCollection":"notes","developmentScheme":false}"#
          .utf8))
  }
  private func folder() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
  private func model(
    _ directory: URL, saved: TestSessionStore = .init(), server: PersonalExampleServer = .init(),
    socket: TestSocket = .init([])
  ) throws -> (PersonalSpaceModel, AuthSession) {
    let config = try config()
    let session = AuthSession(
      configuration: try config.service(config.authURL), store: saved, transport: server)
    return (
      PersonalSpaceModel(
        config: config, session: session, savedSession: saved,
        profiles: PersonalProfiles(fileURL: directory.appending(path: "profiles.json")),
        fileURL: directory.appending(path: "personal.sqlite"),
        transport: server, guestCredentials: MemoryGuestSessionStore(),
        socketFactory: { _ in socket }), session
    )
  }
  private func authenticated(_ session: AuthSession) async throws -> AccountIdentity {
    _ = try await session.authenticate { _ in
      .authenticated(.init(accessToken: "user-token", refreshToken: "synthetic-refresh"))
    }
    return try #require(await session.identity)
  }
  private func wait(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<500 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Expected example state was not reached")
    throw MMGTError.invalidResponse("Timed out awaiting example")
  }
  @Test func personalFixtureAndValidationUseAllFourSharedCollections() throws {
    let values: [JSONValue] = try SharedWireContractTests().decode("sync-personal")
    #expect(Set(values.compactMap { $0["key"]?.string }) == Set(PersonalDomain.collections))
    for value in values {
      #expect(
        value["mode"] == "managed" && value["access_scope"] == "user"
          && value["conflict_policy"] == "reject_stale")
      #expect(value["schema"]?["additionalProperties"] == false)
    }
    let key = ReplicaRecordKey(collection: "personal_tasks", id: "task")
    let valid: JSONValue = [
      "title": "Tea", "listId": .null, "completed": false, "createdAt": "2026-09-12T00:00:00Z",
      "updatedAt": "2026-09-12T00:00:00Z",
    ]
    try PersonalDomain.validate(.init(key: key, data: valid, deleted: false))
    for bad in [JSONValue.string("false"), .null] {
      var changed = try valid.decode([String: JSONValue].self)
      changed["completed"] = bad
      #expect(throws: ReplicaError.invalidRecord) {
        try PersonalDomain.validate(.init(key: key, data: .object(changed), deleted: false))
      }
    }
  }
  @Test func offlineDomainAndConfirmedToolsShareDurableTransactions() async throws {
    let directory = try folder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = PersonalExampleServer()
    let (model, _) = try model(directory, server: server)
    try await model.restoreLocal()
    let domain = try #require(model.domain)
    let list = try await domain.create(kind: .list, title: "Home")
    let task = try await domain.create(kind: .task, title: "Tea", listID: list)
    try await domain.complete(id: task, completed: true)
    let call = AIToolCall(
      id: "stable", name: "create_personal_item",
      arguments: ["kind": "note", "title": "Reminder", "body": "Local", "listId": .string(list)])
    let tool = try #require(domain.tools(requestID: "request", confirm: { _ in true })[call.name])
    let first = try await tool(call.arguments, call)
    let second = try await tool(call.arguments, call)
    #expect(first == second)
    try await domain.remove(kind: .list, id: list)
    #expect(
      try await domain.replica.get(collection: "personal_tasks", id: task)?.data?["listId"] == .null
    )
    #expect(try await domain.replica.list(collection: "personal_notes").count == 1)
    #expect(await server.requests.isEmpty)
    await model.activityChanged(.background)
    let (restored, _) = try self.model(directory, server: server)
    try await restored.restoreLocal()
    #expect(
      try await restored.domain?.replica.get(collection: "personal_tasks", id: task)?.data?[
        "completed"] == true)
    #expect(await server.requests.isEmpty)
    await restored.activityChanged(.background)
  }
  @Test func profileCompareAndSwapAndRefusedToolsCannotCreateEffects() async throws {
    let directory = try folder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let profiles = PersonalProfiles(fileURL: directory.appending(path: "profiles.json"))
    let configuration = try config().service(config().syncURL)
    async let first = profiles.guest(configuration: configuration)
    async let second = profiles.guest(configuration: configuration)
    let (a, b) = try await (first, second)
    #expect(a == b)
    async let nextA = profiles.guest(configuration: configuration, replacing: a)
    async let nextB = profiles.guest(configuration: configuration, replacing: a)
    let (c, d) = try await (nextA, nextB)
    #expect(c == d && c != a)
    let (model, _) = try model(directory)
    try await model.restoreLocal()
    let domain = try #require(model.domain)
    let call = AIToolCall(
      id: "call", name: "create_personal_item", arguments: ["kind": "task", "title": "Declined"])
    let tool = try #require(domain.tools(requestID: "request", confirm: { _ in false })[call.name])
    await #expect(throws: MMGTError.self) { _ = try await tool(call.arguments, call) }
    #expect(try await domain.replica.list(collection: "personal_tasks").isEmpty)
    await model.activityChanged(.background)
  }
  @Test func cachedAccountOpensOfflineButLogoutAndOldViewCannotExposeOrWriteItsData() async throws {
    let directory = try folder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let saved = TestSessionStore()
    let config = try config()
    let server = PersonalExampleServer()
    saved.save(
      .init(
        identity: try .init(configuration: config.service(config.authURL), userID: "user-a"),
        tokens: .init(accessToken: "saved-token", refreshToken: "saved-refresh")))
    let (model, _) = try model(directory, saved: saved, server: server)
    try await model.restoreLocal()
    #expect(model.canSync == false && !model.isGuest)
    let oldView = model.viewID
    let oldDomain = try #require(model.domain)
    _ = try await oldDomain.create(kind: .note, title: "Account only")
    try await model.synchronize()
    #expect(await server.requests.isEmpty)
    saved.clear()
    await model.activityChanged(.signedOut)
    await model.perform(viewID: oldView) {
      _ = try await model.domain?.create(kind: .note, title: "Late view callback")
    }
    #expect(model.isGuest && model.rows.isEmpty)
    await #expect(throws: ReplicaError.closed) {
      _ = try await oldDomain.create(kind: .note, title: "Late tool")
    }
    #expect(try await model.domain?.replica.list(collection: "personal_notes").isEmpty == true)
    await model.activityChanged(.background)
  }
  @Test func existingAccountImportWaitsForConsentAndPreservesListDependencies() async throws {
    let directory = try folder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = PersonalExampleServer()
    let (model, session) = try model(directory, server: server)
    try await model.restoreLocal()
    let list = try await #require(model.domain).create(kind: .list, title: "Device")
    _ = try await #require(model.domain).create(kind: .task, title: "Dependent", listID: list)
    await server.seedNote()
    let identity = try await authenticated(session)
    try await model.bindAccount(identity)
    try await model.synchronize()
    let plan = try #require(model.plan)
    #expect(plan.requiresConfirmation && !plan.committed)
    let count = await server.requests.count
    try await model.synchronize()
    #expect(await server.requests.count == count)
    try await model.approveImport(choices: [:])
    try await model.approveImport(choices: [:])
    try await model.synchronize()
    #expect(await server.applied.map(\.collection) == ["personal_lists", "personal_tasks"])
    try await session.signOutLocally()
    #expect(model.isGuest && model.rows.isEmpty)
    await model.activityChanged(.background)
  }
  @Test func oversizedFinalOrStreamCannotBeTruncatedIntoACompletedReply() async throws {
    for terminal in [true, false] {
      let directory = try folder()
      defer { try? FileManager.default.removeItem(at: directory) }
      let oversized = String(repeating: "😀", count: 20_001)
      var response = WebSocketTests().response()
      response.text = oversized
      let ending: JSONValue =
        terminal
        ? ["type": "response.completed", "response": try .encoding(response)]
        : ["type": "output.text.delta", "delta": .string(oversized)]
      let socket = TestSocket([
        ["type": "authenticated"], ["type": "output.text.delta", "delta": "Saved prefix"], ending,
      ])
      let (model, _) = try model(directory, socket: socket)
      try await model.restoreLocal()
      try await model.loadModels()
      model.ask("Synthetic oversized response", model: try #require(model.models.first))
      try await wait { !model.runningAI }
      let messages = try await #require(model.domain).replica.list(
        collection: "personal_chat_messages")
      let reply = try #require(messages.first { $0.data?["role"] == "assistant" })
      #expect(reply.data?["status"] == "interrupted")
      #expect(reply.data?["text"] == "Saved prefix")
      #expect(model.error != nil)
      #expect(await socket.sent.filter { $0["type"] == "start" }.count == 1)
      await model.activityChanged(.background)
    }
  }
  @Test func streamingToolNeedsConfirmationAndCancellationPersistsAnIncompleteReply() async throws {
    let directory = try folder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let socket = TestSocket([
      ["type": "authenticated"], ["type": "output.text.delta", "delta": "Preparing"],
      [
        "type": "response.requires_action",
        "response": try .encoding(
          WebSocketTests().response(
            status: "requires_action",
            calls: [
              .init(
                id: "tool", name: "create_personal_item",
                arguments: ["kind": "task", "title": "AI task"])
            ])),
      ],
    ])
    let server = PersonalExampleServer()
    let (model, _) = try model(directory, server: server, socket: socket)
    try await model.restoreLocal()
    try await model.loadModels()
    let choice = try #require(model.models.first)
    model.ask("Add tea", model: choice)
    try await wait { model.confirmation != nil }
    #expect(model.streamingText == "Preparing")
    #expect(try await model.domain?.replica.list(collection: "personal_tasks").isEmpty == true)
    model.cancelAI()
    try await wait { !model.runningAI }
    let messages = try await #require(model.domain).replica.list(
      collection: "personal_chat_messages")
    #expect(
      messages.contains { $0.data?["status"] == "interrupted" && $0.data?["text"] == "Preparing" })
    #expect(await socket.sent.filter { $0["type"] == "start" }.count == 1)
    #expect(await socket.sent.filter { $0["type"] == "tool_result" }.isEmpty)
    #expect(try await model.domain?.replica.list(collection: "personal_tasks").isEmpty == true)
    await model.activityChanged(.background)
  }
}

private actor PersonalExampleServer: HTTPTransport {
  var requests: [URLRequest] = [], changes: [SyncChange] = [], applied: [SyncMutationPayload] = []
  private var processed: [String: (SyncMutationPayload, SyncPushResult)] = [:]
  private func response<T: Encodable>(_ value: T) throws -> HTTPResponse {
    .init(data: try JSONEncoder().encode(value), status: 200)
  }
  func seedNote() {
    changes.append(
      .init(
        sequence: "1", collection: "personal_notes", recordId: "remote", op: "upsert", version: "1",
        data: [
          "title": "Existing", "body": "", "listId": .null, "createdAt": "2026-09-12T00:00:00Z",
          "updatedAt": "2026-09-12T00:00:00Z",
        ], userId: "user-a", createdAt: "2026-09-12T00:00:00Z"))
  }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.append(request)
    if request.url?.path.contains("/auth/guest/") == true {
      return try response(
        GuestCredentials(
          guestID: "33333333-3333-4333-8333-333333333333", appID: "app-a",
          issuer: "https://stage.example.invalid/auth",
          accessToken: "mmgt_ga_" + String(repeating: "A", count: 43),
          expiresAt: Date().addingTimeInterval(300).ISO8601Format(),
          idleExpiresAt: Date().addingTimeInterval(30 * 86400).ISO8601Format()))
    }
    if request.url?.path.contains("/auth/") == true {
      return .init(
        data: Data(
          #"{"id":"user-a","email":"a@example.invalid","email_verified":true,"two_fa_enabled":false,"has_password":true,"created_at":"2026-09-09T12:00:00Z","updated_at":"2026-09-09T12:00:00Z"}"#
            .utf8), status: 200)
    }
    if request.url?.lastPathComponent == "catalog" {
      return try response(
        AICatalog(
          status: "available",
          models: [
            .init(
              id: "model", connectionId: "connection", displayName: "Synthetic",
              providerKind: "synthetic", enabled: true, discoveredAt: "2026-09-12T00:00:00Z")
          ]))
    }
    #expect(request.value(forHTTPHeaderField: "X-Sync-User-ID") == "user-a")
    switch request.url?.lastPathComponent {
    case "bootstrap":
      return try response(
        SyncBootstrapResponse(
          collections: PersonalDomain.collections.map {
            .init(
              key: $0, displayName: $0, mode: "managed", accessScope: "user",
              conflictPolicy: "reject_stale", schema: [:], enabled: true,
              createdAt: "2026-09-12T00:00:00Z", updatedAt: "2026-09-12T00:00:00Z")
          }, contractRevision: "2026-09-05", serverTime: "2026-09-12T00:00:00Z", appID: "app-a",
          userID: "user-a"))
    case "snapshot":
      return try response(
        SyncSnapshotResponse(
          records: changes, watermark: String(changes.count), cursor: "cursor", hasMore: false,
          expiresAt: "2030-01-01T00:00:00Z"))
    case "pull":
      return try response(SyncPullResponse(changes: changes, nextCursor: "cursor", hasMore: false))
    case "push":
      let body = try JSONDecoder().decode(SyncPushRequest.self, from: #require(request.httpBody))
      var results: [SyncPushResult] = []
      for mutation in body.mutations {
        let id = body.clientId + "/" + mutation.mutationId
        if let existing = processed[id] {
          #expect(mutation == existing.0)
          results.append(existing.1)
          continue
        }
        let old = changes.last {
          $0.collection == mutation.collection && $0.recordId == mutation.recordId
        }
        #expect(mutation.baseVersion == old?.version ?? "0")
        let version = String(changes.count + 1)
        changes.append(
          .init(
            sequence: version, collection: mutation.collection, recordId: mutation.recordId,
            op: mutation.op, version: version, data: mutation.data, userId: "user-a",
            createdAt: "2026-09-12T00:00:00Z"))
        let result = SyncPushResult(
          mutationId: mutation.mutationId, collection: mutation.collection,
          recordId: mutation.recordId, status: "applied", version: version)
        processed[id] = (mutation, result)
        applied.append(mutation)
        results.append(result)
      }
      return try response(SyncPushResponse(results: results))
    default: throw MMGTError.invalidResponse("Unexpected synthetic request")
    }
  }
}
