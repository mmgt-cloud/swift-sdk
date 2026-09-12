import Foundation
import MMGTAI
import MMGTAuth
import MMGTCore
import MMGTSync
import MMGTSyncSQLite
import Testing

@testable import MMGTExample

private struct GuestProductFailure: Error, CustomStringConvertible {
  let description: String
}

private func requireGuest(_ condition: Bool, _ label: String) throws {
  guard condition else { throw GuestProductFailure(description: label) }
}

private struct GuestProductConfiguration: Decodable, Sendable {
  let environment, appID, userID, email, password, runID: String
  let webRecordID, swiftRecordID, aiConnectionID, aiModel: String
  let authURL, syncURL, aiURL: URL

  static func load() throws -> Self {
    guard let encoded = ProcessInfo.processInfo.environment["MMGT_GUEST_CONFIGURATION"],
      let bytes = Data(base64Encoded: encoded), bytes.count <= 65_536,
      let value = try? JSONDecoder().decode(Self.self, from: bytes),
      ["stage", "prod"].contains(value.environment),
      [
        value.appID, value.userID, value.runID, value.webRecordID, value.swiftRecordID,
        value.aiConnectionID,
      ].allSatisfy({ UUID(uuidString: $0) != nil }),
      !value.email.isEmpty, !value.password.isEmpty, !value.aiModel.isEmpty,
      value.webRecordID != value.swiftRecordID
    else {
      throw GuestProductFailure(description: "Missing explicit isolated guest product fixture")
    }
    let host = value.environment == "stage" ? "api.stage.mmgt.cloud" : "api.mmgt.cloud"
    for (url, path) in [(value.authURL, "/auth"), (value.syncURL, "/sync"), (value.aiURL, "/ai")] {
      try requireGuest(
        url.scheme == "https" && url.host == host && url.path == path
          && url.query == nil && url.fragment == nil && url.user == nil && url.password == nil
          && (url.port == nil || url.port == 443), "Guest fixture crosses its environment")
    }
    return value
  }
  func service(_ url: URL) throws -> ServiceConfiguration { try .init(baseURL: url, appID: appID) }
}

private actor GuestHTTPTrace: HTTPTransport {
  private var count = 0
  private let live = URLSessionTransport()
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    count += 1
    return try await live.send(request)
  }
  func requests() -> Int { count }
}

private actor GuestToolReceipt {
  var calls = 0
  func record() { calls += 1 }
}

/// Explicit live scheme, excluded from default unit/device suites. The web
/// companion imports webRecordID first and reads both exact IDs after this run.
@Suite(.serialized, .timeLimit(.minutes(5))) struct GuestProductTests {
  @Test func offlineGuestAIAndConfirmedImportInteroperateWithWeb() async throws {
    let c = try GuestProductConfiguration.load()
    let folder = URL.applicationSupportDirectory.appending(path: "MMGTGuestTests/\(c.runID)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // Once any provider side effect may have started, this attempt is never
    // rerun automatically, including after app termination or a lost result.
    let attempt = folder.appending(path: "attempted")
    try requireGuest(
      !FileManager.default.fileExists(atPath: attempt.path),
      "Guest attempt already started; reconcile it before a new explicit attempt")
    try Data("single-attempt".utf8).write(to: attempt, options: .withoutOverwriting)
    let trace = GuestHTTPTrace()
    let database = folder.appending(path: "personal.sqlite")
    let store = try SQLiteSyncStore(fileURL: database)
    let identity = try ReplicaIdentity(
      configuration: c.service(c.syncURL), principal: .guest(c.runID))
    let source = try LocalReplica(
      identity: identity, collections: PersonalDomain.collections, store: store,
      validate: PersonalDomain.validate)
    let guest = try GuestSession(
      configuration: c.service(c.authURL), profileID: c.runID, transport: trace)
    let account = AuthSession(configuration: try c.service(c.authURL), transport: trace)
    let ai = AIClient(
      configuration: try c.service(c.aiURL), tokenProvider: await guest.tokenProvider,
      transport: trace)
    var uploadID: String?
    var target: LocalReplica?
    var phase = "offline"
    do {
      let draftID = c.runID
      let date = "2026-09-12T00:00:00Z"
      let draft: JSONValue = [
        "title": "Swift local draft", "body": "Synthetic offline data", "listId": .null,
        "createdAt": .string(date), "updatedAt": .string(date),
      ]
      try await source.upsert(collection: "personal_notes", id: draftID, data: draft)
      let reopened = try LocalReplica(
        identity: identity, collections: PersonalDomain.collections,
        store: SQLiteSyncStore(fileURL: database), validate: PersonalDomain.validate)
      try requireGuest(
        try await reopened.get(collection: "personal_notes", id: draftID)?.data == draft,
        "SQLite restart lost the offline draft")
      let offlineState = try await guest.summary()
      let offlineRequests = await trace.requests()
      try requireGuest(
        offlineState.status == .local && offlineRequests == 0,
        "Offline construction contacted Auth, AI or Sync")
      await reopened.close()
      try await source.delete(collection: "personal_notes", id: draftID)

      phase = "guest-catalog"
      let catalog = try await ai.catalog()
      try requireGuest(
        catalog.models.contains {
          $0.enabled && $0.connectionId == c.aiConnectionID && $0.id == c.aiModel
            && $0.providerKind == "openai-codex"
        }, "Explicit Codex model is unavailable")
      let guestID = try await guest.summary().guestID
      let resumed = try GuestSession(
        configuration: c.service(c.authURL), profileID: c.runID, transport: trace)
      _ = try await resumed.accessToken()
      try requireGuest(
        try await resumed.summary().guestID == guestID && guestID != nil,
        "Restart changed the technical guest identity")
      await resumed.close()

      phase = "guest-http"
      let response = try await ai.generate(
        .init(
          connectionId: c.aiConnectionID, model: c.aiModel,
          input: [
            .init(
              role: "user", content: [.text("Reply with only OK. Synthetic guest SDK acceptance.")])
          ]))
      try requireGuest(
        response.status == "completed" && response.provider == "openai-codex"
          && response.text?.isEmpty == false, "Guest HTTP generation did not complete")

      phase = "guest-upload-and-tool"
      let file = try await ai.upload(
        data: Data("Synthetic acceptance note: Guest note".utf8), filename: "guest-acceptance.txt",
        contentType: "text/plain")
      uploadID = file.id
      let calls = GuestToolReceipt()
      let note: JSONValue = [
        "title": "Guest note", "body": "Created by confirmed Swift AI tool", "listId": .null,
        "createdAt": .string(date), "updatedAt": .string(date),
      ]
      let tool = AIToolDefinition(
        name: "create_acceptance_note",
        description: "Create the explicitly confirmed synthetic local note.",
        parameters: [
          "type": "object", "properties": ["title": ["type": "string", "enum": ["Guest note"]]],
          "required": ["title"], "additionalProperties": false,
        ], strict: true)
      let request = AIResponseRequest(
        connectionId: c.aiConnectionID, model: c.aiModel,
        input: [
          .init(
            role: "user",
            content: [
              .text(
                "Read the attached synthetic text. Call create_acceptance_note exactly once with title Guest note, then reply OK. The test fixture explicitly confirms this one local write."
              ), .file(fileID: file.id),
            ])
        ], tools: [tool])
      let completed = try await ai.runTools(
        request,
        tools: [
          tool.name: { arguments, _ in
            try requireGuest(
              arguments["title"] == "Guest note", "Tool arguments failed app validation")
            try Task.checkCancellation()
            try await source.upsert(collection: "personal_notes", id: c.swiftRecordID, data: note)
            await calls.record()
            return ["recordID": .string(c.swiftRecordID)]
          }
        ], maxIterations: 2)
      let toolCalls = await calls.calls
      try requireGuest(
        completed.status == "completed" && toolCalls == 1,
        "Stream/tool did not complete exactly one validated local effect")
      try requireGuest(
        try await source.get(collection: "personal_notes", id: c.swiftRecordID)?.data == note,
        "UI replica cannot read the tool's local write")
      try await ai.deleteFile(file.id)
      uploadID = nil

      phase = "full-account"
      let login = try await account.authenticate {
        try await $0.login(input: .init(email: c.email, password: c.password))
      }
      guard case .authenticated = login else {
        throw GuestProductFailure(description: "Account has not completed full authentication/MFA")
      }
      try requireGuest(await account.identity?.userID == c.userID, "Account identity mismatch")
      let destination = try LocalReplica(
        identity: .init(configuration: c.service(c.syncURL), principal: .user(c.userID)),
        collections: PersonalDomain.collections, store: store, validate: PersonalDomain.validate)
      target = destination
      await account.attach(destination)
      try await destination.connect(tokenProvider: await account.tokenProvider)
      phase = "web-read-and-import"
      let plan = try await source.prepareImport(to: destination)
      try requireGuest(plan.requiresConfirmation, "Populated web account did not require consent")
      let web = try await destination.get(collection: "personal_notes", id: c.webRecordID)
      try requireGuest(
        web?.data?["title"] == "Imported from web guest",
        "Swift cannot read the exact web-imported record")
      do {
        _ = try await source.approveImport(plan.id, to: destination)
        throw GuestProductFailure(description: "Unconfirmed merge was accepted")
      } catch ReplicaError.confirmationRequired {}
      let adopted = try await source.approveImport(plan.id, to: destination, confirmed: true)
      try requireGuest(adopted.committed, "Import did not durably commit")
      try await drain(destination)
      let progress = try await source.importProgress(plan.id)
      try requireGuest(
        progress.pending == 0 && progress.issues.isEmpty && progress.applied == 1,
        "Import did not reconcile its original delivery")
      try requireGuest(
        try await source.get(collection: "personal_notes", id: c.swiftRecordID)?.data == note,
        "Import deleted the retained guest copy")
      var edited = try requireData(web).decode([String: JSONValue].self)
      edited["title"] = "Edited by Swift"
      try await destination.upsert(
        collection: "personal_notes", id: c.webRecordID, data: .object(edited))
      try await drain(destination)

      phase = "cleanup-local-session"
      await ai.close()
      try await guest.revoke()
      try await account.logout()
      await destination.close()
      await source.close()
    } catch {
      if let uploadID { try? await ai.deleteFile(uploadID) }
      await ai.close()
      try? await guest.revoke()
      try? await account.signOutLocally()
      await target?.close()
      await source.close()
      // API bodies, credentials and user data must never enter test diagnostics.
      throw GuestProductFailure(
        description:
          "Guest product phase \(phase) failed; inspect owned private evidence. No provider retry.")
    }
  }
  private func drain(_ replica: LocalReplica) async throws {
    for _ in 0..<100 {
      let result = try await replica.synchronize()
      let snapshot = try await replica.snapshot()
      if !result.hasMore && snapshot.outbox.isEmpty { return }
    }
    throw GuestProductFailure(description: "Bounded delivery left pending mutations")
  }
  private func requireData(_ record: ReplicaRecord?) throws -> JSONValue {
    guard let data = record?.data else {
      throw GuestProductFailure(description: "Missing web record data")
    }
    return data
  }
}
