import Foundation
import MMGTAI
import MMGTAuth
import MMGTBilling
import MMGTCore
import MMGTRealtime
import MMGTSync
import MMGTSyncSQLite
import Observation
import UIKit

@MainActor @Observable final class ExampleModel {
  let config: ExampleConfiguration
  let auth: AuthState
  let authorizer = OIDCAuthorizer()
  let accountAuthorizer = NativeAccountAuthorizer()
  struct AccountDetails: Sendable {
    let sessions: [SessionResponse]
    let providers: [SocialAccountResponse]
    let passkeys: [PasskeyResponse]
  }
  var accountDetails: AccountDetails?
  var accountMessage: String?
  var billing: BillingAccessState?
  var realtime: RealtimeState?
  var sync: SyncState?
  var ai: AIState?
  var syncClient: SyncClient?
  var records: [SyncRecord] = []
  var issues: [SyncIssue] = []
  var eventLog: [String] = []
  var error: String?
  private var store: SQLiteSyncStore?
  private var account: AccountIdentity?
  init(config: ExampleConfiguration) throws {
    self.config = config
    auth = AuthState(session: AuthSession(configuration: try config.service(config.authURL)))
  }
  var window: UIWindow? {
    UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
      .first { $0.isKeyWindow }
  }
  func action(_ operation: () async throws -> Void) async {
    error = nil
    do { try await operation() } catch is CancellationError {} catch {
      self.error = (error as? APIError)?.message ?? error.localizedDescription
    }
  }
  func connectAccount(_ identity: AccountIdentity?) async throws {
    try Task.checkCancellation()
    guard account != identity else { return }
    account = nil
    billing = nil
    realtime = nil
    sync = nil
    ai = nil
    syncClient = nil
    records = []
    issues = []
    eventLog = []
    accountDetails = nil
    accountMessage = nil
    guard let identity else { return }
    let session = auth.session
    let source = session.tokenProvider
    let store = try SQLiteSyncStore(
      fileURL: URL.applicationSupportDirectory.appending(path: "MMGTExample/sync.sqlite"))
    let syncClient = try SyncClient(
      configuration: config.service(config.syncURL), userID: identity.userID, tokenProvider: source,
      store: store)
    let syncState = syncClient.state(scope: try SyncScope(collections: [config.syncCollection]))
    let realtimeState = RealtimeState(
      client: try RealtimeClient(
        configuration: config.service(config.realtimeURL), userID: identity.userID,
        tokenProvider: source))
    let aiState = try AIState(
      client: AIClient(configuration: config.service(config.aiURL), tokenProvider: source))
    let billingState = BillingClient(
      configuration: try config.service(config.billingURL), tokenProvider: source
    ).accessState()
    for participant: any ApplicationLifecycleParticipant in [
      syncClient, syncState, realtimeState, aiState, billingState,
    ] {
      try Task.checkCancellation()
      guard await session.identity == identity else { throw MMGTError.sessionChanged }
      await session.attach(participant)
    }
    try Task.checkCancellation()
    guard await session.identity == identity else { throw MMGTError.sessionChanged }
    self.store = store
    self.syncClient = syncClient
    sync = syncState
    realtime = realtimeState
    ai = aiState
    billing = billingState
    account = identity
  }
  func oidcLogin() async throws {
    guard let window else { throw MMGTError.invalidConfiguration("No presentation window") }
    let configuration = try NativeOIDCConfiguration(
      auth: config.service(config.authURL), clientID: config.oidcClientID,
      redirectURL: config.redirectURL, allowCustomSchemeForDevelopment: config.developmentScheme)
    let authorizer = authorizer
    _ = try await auth.authenticate { _ in
      try await authorizer.signIn(
        configuration: configuration, presentationAnchor: window, forceLogin: true)
    }
  }
  func passkeyLogin() async throws {
    guard let window else { throw MMGTError.invalidConfiguration("No presentation window") }
    let passkeys = try NativePasskeys(
      relyingPartyID: config.relyingPartyID, presentationAnchor: window)
    _ = try await auth.authenticate { client in try await passkeys.signIn(client: client) }
  }
  func reloadAccountDetails() async throws {
    accountDetails = try await auth.session.performAccountOperation { client in
      async let sessions = client.listSessions()
      async let providers = client.listSocialAccounts()
      async let passkeys = client.listPasskeys()
      return try await AccountDetails(
        sessions: sessions.sessions, providers: providers.socialAccounts,
        passkeys: passkeys.passkeys)
    }
  }
  func linkProvider(_ provider: NativeAccountProvider) async throws {
    guard let window else { throw MMGTError.invalidConfiguration("No presentation window") }
    let native = try NativeOIDCConfiguration(
      auth: config.service(config.authURL), clientID: config.oidcClientID,
      redirectURL: config.redirectURL, allowCustomSchemeForDevelopment: config.developmentScheme)
    _ = try await accountAuthorizer.link(
      provider: provider, configuration: native, session: auth.session, presentationAnchor: window)
    try await reloadAccountDetails()
  }
  func registerPasskey() async throws {
    guard let window else { throw MMGTError.invalidConfiguration("No presentation window") }
    let passkeys = try NativePasskeys(
      relyingPartyID: config.relyingPartyID, presentationAnchor: window)
    _ = try await auth.session.performAccountOperation { client in
      try await passkeys.register(name: "MMGT example passkey", client: client)
    }
    try await reloadAccountDetails()
  }
  func changeEmail(newEmail: String, currentPassword: String) async throws {
    _ = try await auth.session.performAccountOperation { client in
      let proof = try await client.reauthenticateWithPassword(currentPassword: currentPassword)
      return try await client.startEmailChange(newEmail: newEmail, proof: proof)
    }
    accountMessage =
      "Check the new address to confirm the change. Confirmation invalidates existing server sessions."
  }
  func saveNote(_ text: String) async throws {
    guard let syncClient else { throw MMGTError.unauthenticated }
    _ = try await syncClient.write(
      .init(
        collection: config.syncCollection, recordId: UUID().uuidString, op: "upsert",
        data: ["text": .string(text)], baseVersion: "0"))
  }
  func synchronize() async throws {
    guard let sync, let syncClient, let store else { throw MMGTError.unauthenticated }
    let expected = account
    _ = try await sync.reload()
    let nextRecords = try await store.records(
      identity: syncClient.identity, collection: config.syncCollection)
    let nextIssues = try await store.issues(identity: syncClient.identity)
    guard account == expected else { throw MMGTError.sessionChanged }
    records = nextRecords
    issues = nextIssues
  }
  func listen() async throws {
    guard let realtime, let account else { return }
    let client = realtime.client
    let messages = await client.messages()
    try await client.subscribe(.init(channel: RealtimeChannels.user(account.userID)))
    try await realtime.connect()
    var seen: Set<String> = []
    for try await message in messages {
      try Task.checkCancellation()
      guard self.account == account else { throw MMGTError.sessionChanged }
      switch message {
      case .event(let event):
        let domainID = event.payload["event_id"]?.string ?? event.payload["id"]?.string ?? event.id
        if seen.insert(domainID).inserted {
          eventLog.append(event.eventType + ": " + domainID)
          if eventLog.count > 100 { eventLog.removeFirst() }
          if seen.count > 4096 { seen = [domainID] }
        }
        // The domain effect above has been applied before transport acknowledgment.
        try await client.acknowledge(event)
      case .replayGap:
        // Re-fetch domain data. A replay gap cannot be repaired by an ACK.
        try await synchronize()
      default: break
      }
    }
  }
}
