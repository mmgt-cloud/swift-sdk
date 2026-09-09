import Foundation
import MMGTCore
import Security
import Synchronization
import Testing

@testable import MMGTAuth

private final class MemoryTrustedDeviceStore: TrustedDeviceStore, Sendable {
  let state = Mutex<TrustedDeviceCredential?>(nil)
  func load() -> TrustedDeviceCredential? { state.withLock { $0 } }
  func save(_ credential: TrustedDeviceCredential) { state.withLock { $0 = credential } }
  func clear() { state.withLock { $0 = nil } }
}

@Suite(.timeLimit(.minutes(1))) struct TrustedDeviceTests {
  private let email = "synthetic@example.invalid"
  private let token = String(repeating: "a", count: 64)
  private let challenge = #"{"requires_2fa":true,"temp_token":"synthetic-temp","method":"totp"}"#
  private let authenticated =
    #"{"access_token":"synthetic-access","refresh_token":"synthetic-refresh"}"#
  private func config(_ host: String = "stage.example.invalid", app: String = "synthetic-app")
    throws -> ServiceConfiguration
  {
    try ServiceConfiguration(baseURL: URL(string: "https://\(host)/auth")!, appID: app)
  }
  private var cookie: String {
    "trusted_device=\(token); Path=/; Max-Age=86400; HttpOnly; Secure; SameSite=None"
  }

  @Test func remembersOnlyVerifiedPasswordMFAAndOnlySendsToLogin() async throws {
    let configuration = try config()
    let base = RecordingTransport([
      .init(data: Data(challenge.utf8), status: 202),
      .init(data: Data(authenticated.utf8), status: 200, headers: ["Set-Cookie": cookie]),
      .init(data: Data(authenticated.utf8), status: 200),
      .init(data: Data(authenticated.utf8), status: 200),
      .init(data: Data(#"{"message":"Revoked"}"#.utf8), status: 200),
    ])
    let store = MemoryTrustedDeviceStore()
    let transport = try TrustedDeviceTransport(
      configuration: configuration, email: email, transport: base, store: store)
    let client = AuthClient(
      configuration: configuration, tokenProvider: { "synthetic-access" }, transport: transport)
    _ = try await client.login(input: .init(email: email, password: "synthetic-password"))
    _ = try await client.verify2FALogin(
      input: .init(tempToken: "synthetic-temp", code: "123456", rememberDevice: true))
    #expect(try await transport.isRemembered())
    // A new adapter uses the same account partition across application restart.
    let restarted = try TrustedDeviceTransport(
      configuration: configuration, email: email, transport: base, store: store)
    let next = AuthClient(configuration: configuration, transport: restarted)
    _ = try await next.login(input: .init(email: email, password: "synthetic-password"))
    _ = try await next.refreshToken("synthetic-refresh")
    _ = try await client.revokeAllTrustedDevices()
    #expect(try await restarted.isRemembered() == false)
    let requests = await base.requests
    #expect(
      requests.map { $0.value(forHTTPHeaderField: "Cookie") } == [
        nil, nil, "trusted_device=" + token, nil, nil,
      ])
    #expect(
      !requests.contains { $0.value(forHTTPHeaderField: "Cookie")?.contains("Secure") == true })
  }

  @Test func accountEnvironmentApplicationAndChallengeAreFenced() async throws {
    let configuration = try config()
    let base = RecordingTransport([])
    let transport = try TrustedDeviceTransport(
      configuration: configuration, email: email, transport: base, store: MemoryTrustedDeviceStore()
    )
    for pair in [
      (try config("prod.example.invalid"), email), (try config(app: "other-app"), email),
      (configuration, "other@example.invalid"),
    ] {
      let client = AuthClient(configuration: pair.0, transport: transport)
      await #expect(throws: MMGTError.sessionChanged) {
        try await client.login(input: .init(email: pair.1, password: "synthetic"))
      }
    }
    let client = AuthClient(configuration: configuration, transport: transport)
    await #expect(throws: MMGTError.self) {
      try await client.verify2FALogin(
        input: .init(tempToken: "foreign-challenge", code: "123456", rememberDevice: true))
    }
    let defaultClient = AuthClient(configuration: configuration, transport: base)
    await #expect(throws: MMGTError.self) {
      try await defaultClient.verify2FALogin(
        input: .init(tempToken: "synthetic-temp", code: "123456", rememberDevice: true))
    }
    #expect(await base.requests.isEmpty)
  }

  @Test func insecureMalformedAndFailedMFACookiesCannotBecomeTrust() async throws {
    for header in [
      cookie.replacingOccurrences(of: "; Secure", with: ""),
      cookie.replacingOccurrences(of: "; HttpOnly", with: ""),
      cookie + "; Domain=foreign.example.invalid",
      cookie.replacingOccurrences(of: token, with: "bad-token"),
    ] {
      let configuration = try config()
      let base = RecordingTransport([
        .init(data: Data(challenge.utf8), status: 202),
        .init(data: Data(authenticated.utf8), status: 200, headers: ["Set-Cookie": header]),
      ])
      let store = MemoryTrustedDeviceStore()
      let transport = try TrustedDeviceTransport(
        configuration: configuration, email: email, transport: base, store: store)
      let client = AuthClient(configuration: configuration, transport: transport)
      _ = try await client.login(input: .init(email: email, password: "synthetic"))
      await #expect(throws: MMGTError.self) {
        try await client.verify2FALogin(
          input: .init(tempToken: "synthetic-temp", code: "123456", rememberDevice: true))
      }
      #expect(store.load() == nil)
    }
    let configuration = try config()
    let store = MemoryTrustedDeviceStore()
    store.save(.init(token: token, expiresAt: .distantPast))
    let base = RecordingTransport([
      .init(data: Data(challenge.utf8), status: 202),
      .init(
        data: Data(#"{"error":"Invalid MFA"}"#.utf8), status: 401, headers: ["Set-Cookie": cookie]),
    ])
    let transport = try TrustedDeviceTransport(
      configuration: configuration, email: email, transport: base, store: store)
    let client = AuthClient(configuration: configuration, transport: transport)
    #expect(try await transport.isRemembered() == false)
    _ = try await client.login(input: .init(email: email, password: "synthetic"))
    await #expect(throws: APIError.self) {
      try await client.verify2FALogin(
        input: .init(tempToken: "synthetic-temp", code: "123456", rememberDevice: true))
    }
    #expect(await base.requests[0].value(forHTTPHeaderField: "Cookie") == nil)
    #expect(store.load()?.expiresAt == .distantPast)
  }

  @Test func forgetAndCancellationRejectLateMFAWithoutRetry() async throws {
    for cancel in [false, true] {
      let configuration = try config()
      let base = ControlledTransport()
      let store = MemoryTrustedDeviceStore()
      let transport = try TrustedDeviceTransport(
        configuration: configuration, email: email, transport: base, store: store)
      let client = AuthClient(configuration: configuration, transport: transport)
      let first = Task { try await client.login(input: .init(email: email, password: "synthetic")) }
      await base.waitForRequest(0)
      await base.reply(0, challenge, status: 202)
      _ = try await first.value
      let second = Task {
        try await client.verify2FALogin(
          input: .init(tempToken: "synthetic-temp", code: "123456", rememberDevice: true))
      }
      await base.waitForRequest(1)
      if cancel { second.cancel() } else { try await transport.forget() }
      await base.reply(1, authenticated, headers: ["Set-Cookie": cookie])
      if cancel {
        await #expect(throws: CancellationError.self) { try await second.value }
      } else {
        await #expect(throws: MMGTError.sessionChanged) { try await second.value }
      }
      #expect(store.load() == nil)
      #expect(await base.requests.count == 2)
    }
  }

  @Test func keychainPartitionsAndFailedForgetRemainSafeAfterRestart() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let keychain = FaultKeychain()
    let configuration = try config()
    let original = KeychainTrustedDeviceStore(
      configuration: configuration, email: email, keychain: keychain, directory: directory)
    let others = [
      KeychainTrustedDeviceStore(
        configuration: try config("prod.example.invalid"), email: email, keychain: keychain,
        directory: directory),
      KeychainTrustedDeviceStore(
        configuration: try config(app: "other-app"), email: email, keychain: keychain,
        directory: directory),
      KeychainTrustedDeviceStore(
        configuration: configuration, email: "other@example.invalid", keychain: keychain,
        directory: directory),
    ]
    try original.save(.init(token: token, expiresAt: .distantFuture))
    for other in others { #expect(try other.load() == nil) }
    keychain.state.withLock { $0.failDelete = true }
    #expect(throws: KeychainError.self) { try original.clear() }
    let restarted = KeychainTrustedDeviceStore(
      configuration: configuration, email: email, keychain: keychain, directory: directory)
    #expect(try restarted.load() == nil)
    keychain.state.withLock {
      $0.failDelete = false
      $0.failSave = true
    }
    #expect(throws: KeychainError.self) {
      try restarted.save(.init(token: token, expiresAt: .distantFuture))
    }
    #expect(try restarted.load() == nil)
    for url in try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    {
      let text = try String(contentsOf: url, encoding: .utf8)
      #expect(!text.contains(token) && !text.contains(email))
    }
    #expect(
      try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    )
  }
}
