import Foundation
import MMGTAI
import MMGTAuth
import MMGTBilling
import MMGTCore
import MMGTRealtime
import MMGTSync
import MMGTSyncSQLite
import Testing

private struct LiveFailure: Error, CustomStringConvertible {
  let description: String
}

private struct LiveConfiguration: Decodable, Sendable {
  let environment, appID, userID, email, password, runID, collection: String
  let authURL, billingURL, realtimeURL, syncURL, aiURL: URL
  let realtimeGrant, aiConnectionID, aiModel: String

  static func load() throws -> Self {
    guard let encoded = ProcessInfo.processInfo.environment["MMGT_LIVE_CONFIGURATION"],
      let bytes = Data(base64Encoded: encoded), bytes.count <= 65_536,
      let value = try? JSONDecoder().decode(Self.self, from: bytes),
      ["stage", "prod"].contains(value.environment), UUID(uuidString: value.runID) != nil,
      UUID(uuidString: value.appID) != nil, UUID(uuidString: value.userID) != nil,
      !value.password.isEmpty, !value.realtimeGrant.isEmpty,
      !value.aiConnectionID.isEmpty, !value.aiModel.isEmpty,
      !value.collection.isEmpty
    else { throw LiveFailure(description: "Missing or invalid explicit live-test configuration") }
    let urls = [value.authURL, value.billingURL, value.realtimeURL, value.syncURL, value.aiURL]
    let expectedHost = value.environment == "stage" ? "api.stage.mmgt.cloud" : "api.mmgt.cloud"
    guard
      urls.allSatisfy({
        $0.scheme == "https" && $0.host == expectedHost && $0.query == nil && $0.fragment == nil
          && $0.user == nil && $0.password == nil
      })
    else {
      throw LiveFailure(
        description: "Live-test service URLs cross the selected platform environment")
    }
    return value
  }
  func service(_ url: URL) throws -> ServiceConfiguration {
    try .init(baseURL: url, appID: appID)
  }
}

/// Deliberately absent from the ordinary SPM/synthetic-device scheme. Running this
/// suite requires explicit live credentials; missing dependencies fail, never skip.
@Suite(.serialized, .timeLimit(.minutes(3))) struct LiveServiceTests {
  @Test func fiveServicesThroughPublicAPIs() async throws {
    let c = try LiveConfiguration.load()
    let session = AuthSession(configuration: try c.service(c.authURL))
    var phase = "auth"
    do {
      let login = try await session.authenticate { client in
        try await client.login(input: .init(email: c.email, password: c.password))
      }
      guard case .authenticated = login, await session.identity?.userID == c.userID else {
        throw LiveFailure(
          description:
            "The live fixture did not complete password authentication for its expected account")
      }
      let profile = try await session.performAccountOperation { try await $0.getProfile() }
      guard profile.id == c.userID else {
        throw LiveFailure(description: "Profile identity mismatch")
      }

      phase = "sync"
      let database = URL.applicationSupportDirectory.appending(
        path: "MMGTLiveTests/\(c.runID).sqlite")
      let local = try SQLiteSyncStore(fileURL: database)
      let sync = try SyncClient(
        configuration: c.service(c.syncURL), userID: c.userID,
        tokenProvider: session.tokenProvider, store: local)
      await session.attach(sync)
      let bootstrap = try await sync.bootstrap()
      guard
        bootstrap.collections.contains(where: {
          $0.key == c.collection && $0.conflictPolicy == "reject_stale"
            && $0.enabled && $0.accessScope == "user" && $0.mode != "projected"
        })
      else {
        throw LiveFailure(
          description: "The live fixture requires a writable reject_stale collection")
      }
      let scope = try SyncScope(collections: [c.collection])
      try await sync.write(
        .init(
          collection: c.collection, recordId: c.runID, op: "upsert",
          data: ["text": .string("sdk-live-" + c.runID)], mutationId: c.runID + "-create",
          baseVersion: "0"))
      let first = try await sync.sync(scope: scope)
      guard !first.hasMore,
        let record = try await sync.getLocalRecord(collection: c.collection, id: c.runID),
        !record.deleted, record.data?["text"]?.string == "sdk-live-" + c.runID
      else {
        throw LiveFailure(description: "Sync did not recover the fixture's committed record")
      }
      try await sync.write(
        .init(
          collection: c.collection, recordId: c.runID, op: "upsert",
          data: ["text": "stale"], mutationId: c.runID + "-conflict", baseVersion: "0"))
      _ = try await sync.sync(scope: scope)
      let conflicts = try await sync.listLocalConflicts()
      guard
        conflicts.contains(where: {
          $0.entry.mutation.mutationId == c.runID + "-conflict" && $0.result.status == "conflict"
        })
      else {
        throw LiveFailure(description: "Sync did not preserve the expected CAS conflict")
      }
      _ = try await sync.rebuild(scope: scope)
      guard
        try await sync.getLocalRecord(collection: c.collection, id: c.runID)?.version
          == record.version
      else {
        throw LiveFailure(description: "Snapshot recovery changed the authoritative record version")
      }

      phase = "realtime"
      let realtime = try RealtimeClient(
        configuration: c.service(c.realtimeURL), userID: c.userID,
        tokenProvider: session.tokenProvider, autoReconnect: false)
      await session.attach(realtime)
      let channel = "sdk-live:" + c.runID
      let messages = await realtime.messages()
      var events = messages.makeAsyncIterator()
      try await realtime.connect()
      try await realtime.subscribe(.init(channel: channel, grantProvider: { _ in c.realtimeGrant }))
      var subscribed = false
      while let event = try await events.next() {
        if case .subscribed(let value) = event, value == channel {
          subscribed = true
          break
        }
        if case .error = event { throw LiveFailure(description: "Realtime subscription rejected") }
      }
      guard subscribed else {
        throw LiveFailure(description: "Realtime subscription was not confirmed")
      }
      try await realtime.publish(
        channel: channel, eventType: "sdk.smoke", payload: ["runID": .string(c.runID)],
        grant: c.realtimeGrant)
      var eventID: String?
      while let message = try await events.next() {
        if case .event(let event) = message, event.channel == channel,
          event.payload["runID"]?.string == c.runID
        {
          eventID = event.id
          try await realtime.acknowledge(event)
          break
        }
        if case .error = message { throw LiveFailure(description: "Realtime publication rejected") }
      }
      guard let eventID else { throw LiveFailure(description: "Realtime event was not delivered") }
      var confirmed = false
      while let message = try await events.next() {
        if case .acknowledged(let acknowledgedChannel, let acknowledgedID, _) = message,
          acknowledgedChannel == channel, acknowledgedID == eventID
        {
          confirmed = true
          break
        }
        if case .error = message {
          throw LiveFailure(description: "Realtime acknowledgement rejected")
        }
      }
      guard confirmed else {
        throw LiveFailure(description: "Realtime transport ACK was not confirmed")
      }
      await realtime.close()

      phase = "billing"
      let billing = BillingClient(
        configuration: try c.service(c.billingURL), tokenProvider: session.tokenProvider)
      _ = try await billing.getCatalog()
      _ = try await billing.getAccess()
      _ = try await billing.listWorkspaces()

      phase = "ai"
      let ai = AIClient(configuration: try c.service(c.aiURL), tokenProvider: session.tokenProvider)
      await session.attach(ai)
      let catalog = try await ai.catalog()
      guard
        catalog.models.contains(where: {
          $0.connectionId == c.aiConnectionID && $0.id == c.aiModel && $0.enabled
        })
      else {
        throw LiveFailure(description: "The selected existing AI connection/model is unavailable")
      }
      let request = AIResponseRequest(
        connectionId: c.aiConnectionID, model: c.aiModel,
        input: [.init(role: "user", content: [.text("Reply with only OK.")])])
      let response = try await ai.generate(request)
      guard response.status == "completed", response.text?.isEmpty == false else {
        throw LiveFailure(description: "AI HTTP response did not complete")
      }
      var completed = false
      for try await event in try await ai.stream(request) {
        if case .completed(let result) = event {
          completed = result.status == "completed" && result.text?.isEmpty == false
        }
        if case .failed = event {
          throw LiveFailure(
            description: "AI stream returned a provider error; no retry was attempted")
        }
      }
      guard completed else { throw LiveFailure(description: "AI stream did not complete") }
      phase = "logout"
      try await session.logout()
    } catch {
      // Local account cleanup must still happen; fixture/domain cleanup belongs to
      // the platform's ownership-fenced runner. No provider or mutation is replayed.
      try? await session.signOutLocally()
      let code = (error as? APIError)?.code ?? "failed"
      throw LiveFailure(
        description:
          "Live phase \(phase) failed (\(code)); inspect private evidence. No automatic retry.")
    }
  }
}
