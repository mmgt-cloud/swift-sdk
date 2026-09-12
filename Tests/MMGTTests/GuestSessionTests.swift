import Foundation
import MMGTCore
import Security
import Synchronization
import Testing

@testable import MMGTAuth

private final class FaultGuestStore: GuestSessionStore, Sendable {
  let memory = MemoryGuestSessionStore()
  let fail = Mutex(false)
  func load(partition: String) throws -> GuestStoredSession? {
    if fail.withLock({ $0 }) { throw KeychainError(status: errSecInteractionNotAllowed) }
    return memory.load(partition: partition)
  }
  func compareAndSwap(partition: String, expectedRevision: String?, next: GuestStoredSession) throws
    -> Bool
  {
    if fail.withLock({ $0 }) { throw KeychainError(status: errSecInteractionNotAllowed) }
    return try memory.compareAndSwap(
      partition: partition, expectedRevision: expectedRevision, next: next)
  }
}

@Suite(.timeLimit(.minutes(1))) struct GuestSessionTests {
  private let time = Date(timeIntervalSince1970: 1_789_171_200)
  private let guestID = "33333333-3333-4333-8333-333333333333"
  private var access: String { "mmgt_ga_" + String(repeating: "A", count: 43) }
  private func configuration(_ host: String = "stage.example.invalid", app: String = "app") throws
    -> ServiceConfiguration
  {
    try .init(baseURL: URL(string: "https://\(host)/auth")!, appID: app)
  }
  private func credentials(
    _ date: Date? = nil, app: String = "app", issuer: String = "https://stage.example.invalid/auth",
    id: String? = nil
  ) -> GuestCredentials {
    let start = date ?? time
    return .init(
      guestID: id ?? guestID, appID: app, issuer: issuer, accessToken: access,
      expiresAt: start.addingTimeInterval(300).ISO8601Format(),
      idleExpiresAt: start.addingTimeInterval(30 * 86400).ISO8601Format())
  }
  private func reply(_ transport: ControlledTransport, _ index: Int, _ value: GuestCredentials)
    async throws
  {
    await transport.reply(index, String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
  }
  private func session(
    store: any GuestSessionStore, transport: any HTTPTransport, profile: String = "local-profile"
  ) throws -> GuestSession {
    let time = self.time
    return try GuestSession(
      configuration: configuration(), profileID: profile, store: store, transport: transport,
      now: { time })
  }
  @Test func sharedGuestFixturesPreserveCredentialsPolicyAndDecimalRevision() throws {
    let fixtures = SharedWireContractTests()
    let credentials = try fixtures.roundTrip("auth-guestsession", as: GuestCredentials.self)
    #expect(credentials.purpose == "ai" && credentials.accessToken.hasPrefix("mmgt_ga_"))
    #expect(credentials.guestID == "33333333-3333-4333-8333-333333333333")
    let policy = try fixtures.decode("auth-guestpolicy", as: JSONValue.self)
    let authorization = try fixtures.decode("ai-guestauthorization", as: JSONValue.self)
    #expect(policy["revision"]?.string == "9007199254740993")
    #expect(authorization["policy"] == policy["policy"])
    #expect(authorization["guest_id"]?.string == credentials.guestID)
    #expect(authorization["access_token"] == nil)
  }
  @Test func offlineConstructionAndSummaryDoNotContactAuth() async throws {
    let transport = ControlledTransport()
    let disk = MemoryGuestSessionStore()
    let sdk = try session(store: disk, transport: transport)
    #expect(try await sdk.summary().status == .local)
    #expect(await transport.requests.isEmpty)
    #expect(disk.load(partition: sdk.partition) == nil)
    await sdk.close()
  }
  @Test func snapshotSequencePublishesAccessAndFinishesOnCloseWithoutNetworkRetry() async throws {
    let network = ControlledTransport()
    let disk = MemoryGuestSessionStore()
    let sdk = try session(store: disk, transport: network)
    var iterator = try await sdk.snapshots().makeAsyncIterator()
    #expect(await iterator.next()?.status == .local)
    let request = Task { try await sdk.accessToken() }
    await network.waitForRequest(0)
    try await reply(network, 0, credentials())
    _ = try await request.value
    #expect(await iterator.next()?.status == .active)
    await sdk.close()
    #expect(await iterator.next() == nil)
    #expect(await network.requests.count == 1)
  }
  @Test func coalescesRequestsAndPersistsTheRenewalSecretBeforeFirstNetworkCall() async throws {
    let transport = ControlledTransport()
    let disk = MemoryGuestSessionStore()
    let sdk = try session(store: disk, transport: transport)
    let one = Task { try await sdk.accessToken() }
    let two = Task { try await sdk.accessToken() }
    await transport.waitForRequest(0)
    let saved = try #require(disk.load(partition: sdk.partition))
    #expect(saved.renewalSecret?.hasPrefix("mmgt_gr_") == true)
    #expect(saved.credentials == nil)
    let requests = await transport.requests
    #expect(requests.count == 1 && requests[0].url?.path == "/auth/guest/sessions")
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
    #expect(requests[0].value(forHTTPHeaderField: "X-App-ID") == "app")
    #expect(requests[0].url?.query == nil)
    let payload = try JSONDecoder().decode(
      [String: String].self, from: #require(requests[0].httpBody))
    #expect(payload == ["renewal_secret": saved.renewalSecret!])
    try await reply(transport, 0, credentials())
    #expect(try await one.value == access)
    #expect(try await two.value == access)
    await sdk.close()
    let restored = try session(store: disk, transport: transport)
    #expect(try await restored.accessToken() == access)
    #expect(await transport.requests.count == 1)
    await restored.close()
  }
  @Test func lostCreateResponseRecoversUsingTheSameSavedCredential() async throws {
    let transport = ControlledTransport()
    let disk = MemoryGuestSessionStore()
    let sdk = try session(store: disk, transport: transport)
    let first = Task { try await sdk.accessToken() }
    await transport.waitForRequest(0)
    await transport.reply(0, #"{"code":"guest_unavailable"}"#, status: 503)
    await #expect(throws: APIError.self) { try await first.value }
    let secret = disk.load(partition: sdk.partition)?.renewalSecret
    await sdk.close()
    let restored = try session(store: disk, transport: transport)
    let retry = Task { try await restored.accessToken() }
    await transport.waitForRequest(1)
    let requests = await transport.requests
    #expect(requests[0].httpBody == requests[1].httpBody)
    #expect(disk.load(partition: restored.partition)?.renewalSecret == secret)
    try await reply(transport, 1, credentials())
    #expect(try await retry.value == access)
    await restored.close()
  }
  @Test func concurrentOwnersShareIdentityAndCannotOverwriteRevocation() async throws {
    let disk = MemoryGuestSessionStore()
    let transport = ControlledTransport()
    let a = try session(store: disk, transport: transport)
    let b = try session(store: disk, transport: transport)
    let first = Task { try await a.accessToken() }
    await transport.waitForRequest(0)
    let second = Task { try await b.accessToken() }
    await transport.waitForRequest(1)
    let requests = await transport.requests
    #expect(requests[0].httpBody == requests[1].httpBody)
    let revoke = Task { try await b.revoke() }
    await transport.waitForRequest(2)
    #expect(disk.load(partition: a.partition)?.phase == .revoking)
    await transport.reply(2, "", status: 204)
    try await revoke.value
    try await reply(transport, 0, credentials())
    try await reply(transport, 1, credentials())
    await #expect(throws: GuestSessionError("guest_session_revoked")) { try await first.value }
    await #expect(throws: (any Error).self) { try await second.value }
    #expect(disk.load(partition: a.partition)?.phase == .revoked)
    #expect(disk.load(partition: a.partition)?.renewalSecret == nil)
    await a.close()
    await b.close()
  }
  @Test func refreshAfterExpiryRetainsGuestIdentityAndOnlyRefreshesOnce() async throws {
    let transport = ControlledTransport()
    let disk = MemoryGuestSessionStore()
    let clock = Mutex(time)
    let sdk = try GuestSession(
      configuration: configuration(), profileID: "profile", store: disk, transport: transport,
      now: { clock.withLock { $0 } })
    let first = Task { try await sdk.accessToken() }
    await transport.waitForRequest(0)
    try await reply(transport, 0, credentials())
    _ = try await first.value
    clock.withLock { $0 = $0.addingTimeInterval(290) }
    let one = Task { try await sdk.accessToken() }
    let two = Task { try await sdk.accessToken() }
    await transport.waitForRequest(1)
    #expect(await transport.requests[1].url?.path == "/auth/guest/sessions/renew")
    try await reply(transport, 1, credentials(time.addingTimeInterval(290)))
    #expect(try await one.value == access)
    #expect(try await two.value == access)
    #expect(disk.load(partition: sdk.partition)?.credentials?.guestID == guestID)
    #expect(await transport.requests.count == 2)
    await sdk.close()
  }
  @Test func closeFencesLateResponsesEvenWhenTransportIgnoresCancellation() async throws {
    let transport = ControlledTransport()
    let disk = MemoryGuestSessionStore()
    let sdk = try session(store: disk, transport: transport)
    let token = await sdk.tokenProvider
    let pending = Task { try await token() }
    await transport.waitForRequest(0)
    await sdk.close()
    try await reply(transport, 0, credentials())
    await #expect(throws: MMGTError.sessionChanged) { try await pending.value }
    #expect(disk.load(partition: sdk.partition)?.credentials == nil)
    await #expect(throws: MMGTError.sessionChanged) { try await token() }
  }
  @Test func quotaDoesNotRetryOrResetAndExpiredSessionNeedsExplicitReset() async throws {
    let transport = ControlledTransport()
    let disk = MemoryGuestSessionStore()
    let sdk = try session(store: disk, transport: transport)
    let first = Task { try await sdk.accessToken() }
    await transport.waitForRequest(0)
    let secret = disk.load(partition: sdk.partition)?.renewalSecret
    await transport.reply(0, #"{"code":"guest_session_limit"}"#, status: 429)
    await #expect(throws: APIError.self) { try await first.value }
    #expect(await transport.requests.count == 1)
    await #expect(throws: GuestSessionError("guest_previous_session_active")) {
      try await sdk.startNewSession()
    }
    let second = Task { try await sdk.accessToken() }
    await transport.waitForRequest(1)
    await transport.reply(1, #"{"code":"guest_session_expired"}"#, status: 410)
    await #expect(throws: APIError.self) { try await second.value }
    #expect(disk.load(partition: sdk.partition)?.phase == .expired)
    await #expect(throws: GuestSessionError("guest_session_expired")) {
      try await sdk.accessToken()
    }
    try await sdk.startNewSession()
    #expect(disk.load(partition: sdk.partition)?.renewalSecret != secret)
    #expect(await transport.requests.count == 2)
    await sdk.close()
  }
  @Test func failedRevocationRetainsARecoverableMarkerAcrossRestart() async throws {
    let transport = ControlledTransport()
    let disk = MemoryGuestSessionStore()
    let sdk = try session(store: disk, transport: transport)
    let first = Task { try await sdk.accessToken() }
    await transport.waitForRequest(0)
    try await reply(transport, 0, credentials())
    _ = try await first.value
    let revoke = Task { try await sdk.revoke() }
    await transport.waitForRequest(1)
    await transport.reply(1, #"{"code":"guest_unavailable"}"#, status: 503)
    await #expect(throws: APIError.self) { try await revoke.value }
    #expect(disk.load(partition: sdk.partition)?.phase == .revoking)
    await sdk.close()
    let restored = try session(store: disk, transport: transport)
    await #expect(throws: GuestSessionError("guest_session_revoked")) {
      try await restored.accessToken()
    }
    let retry = Task { try await restored.revoke() }
    await transport.waitForRequest(2)
    #expect(await transport.requests[1].httpBody == transport.requests[2].httpBody)
    await transport.reply(2, "", status: 204)
    try await retry.value
    #expect(disk.load(partition: restored.partition)?.phase == .revoked)
    await restored.close()
  }
  @Test func keychainFailureBlocksNetworkAndCachedAccess() async throws {
    let transport = ControlledTransport()
    let disk = FaultGuestStore()
    let sdk = try session(store: disk, transport: transport)
    disk.fail.withLock { $0 = true }
    await #expect(throws: KeychainError(status: errSecInteractionNotAllowed)) {
      try await sdk.accessToken()
    }
    #expect(await transport.requests.isEmpty)
    disk.fail.withLock { $0 = false }
    let initial = Task { try await sdk.accessToken() }
    await transport.waitForRequest(0)
    try await reply(transport, 0, credentials())
    _ = try await initial.value
    disk.fail.withLock { $0 = true }
    await #expect(throws: KeychainError.self) { try await sdk.accessToken() }
    #expect(await transport.requests.count == 1)
    await sdk.close()
  }
  @Test func separatesAppEnvironmentAndLocalProfileAndRejectsForeignResponses() async throws {
    let transport = ControlledTransport()
    let disk = MemoryGuestSessionStore()
    let time = self.time
    let a = try session(store: disk, transport: transport)
    let b = try session(store: disk, transport: transport, profile: "another")
    let c = try GuestSession(
      configuration: configuration("prod.example.invalid"), profileID: "local-profile", store: disk,
      transport: transport, now: { time })
    let d = try GuestSession(
      configuration: configuration(app: "other"), profileID: "local-profile", store: disk,
      transport: transport, now: { time })
    #expect(Set([a.partition, b.partition, c.partition, d.partition]).count == 4)
    let request = Task { try await a.accessToken() }
    await transport.waitForRequest(0)
    try await reply(transport, 0, credentials(app: "other"))
    await #expect(throws: GuestSessionError("guest_invalid_response")) { try await request.value }
    #expect(disk.load(partition: a.partition)?.credentials == nil)
    #expect(disk.load(partition: b.partition) == nil)
    await a.close()
    await b.close()
    await c.close()
    await d.close()
  }
}
