import Foundation
import MMGTCore
import Security
import Synchronization
import Testing

@testable import MMGTAuth

final class FaultKeychain: KeychainDataAccess, Sendable {
  struct State: Sendable {
    var values: [String: Data] = [:]
    var failDelete = false
    var failSave = false
    var failLoad = false
  }
  let state = Mutex(State())
  func load(key: String) throws -> Data? {
    try state.withLock { state in
      if state.failLoad { throw KeychainError(status: errSecInteractionNotAllowed) }
      return state.values[key]
    }
  }
  func save(_ data: Data, key: String) throws {
    try state.withLock { state in
      if state.failSave { throw KeychainError(status: errSecInteractionNotAllowed) }
      state.values[key] = data
    }
  }
  func clear(key: String) throws {
    try state.withLock { state in
      if state.failDelete { throw KeychainError(status: errSecInteractionNotAllowed) }
      state.values[key] = nil
    }
  }
}

@Suite struct KeychainStoreTests {
  private func config(_ host: String = "stage.example.invalid", app: String = "synthetic-app")
    throws -> ServiceConfiguration
  {
    try ServiceConfiguration(baseURL: URL(string: "https://\(host)/auth")!, appID: app)
  }
  private func session(_ configuration: ServiceConfiguration, user: String = "synthetic-user")
    throws -> PersistedSession
  {
    PersistedSession(
      identity: try AccountIdentity(configuration: configuration, userID: user),
      tokens: .init(accessToken: "synthetic-access", refreshToken: "synthetic-refresh"))
  }
  @Test func failedKeychainDeletionCannotRestoreAfterRestart() throws {
    let configuration = try config()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let keychain = FaultKeychain()
    let store = KeychainSessionStore(
      configuration: configuration, keychain: keychain, directory: directory)
    let value = try session(configuration)
    try store.save(value)
    #expect(try store.load() == value)
    keychain.state.withLock { $0.failDelete = true }
    #expect(throws: KeychainError(status: errSecInteractionNotAllowed)) { try store.clear() }
    #expect(keychain.state.withLock { !$0.values.isEmpty })
    let restarted = KeychainSessionStore(
      configuration: configuration, keychain: keychain, directory: directory)
    #expect(try restarted.load() == nil)
    keychain.state.withLock { $0.failDelete = false }
    try restarted.clear()
    #expect(keychain.state.withLock { $0.values.isEmpty })
    let replacement = try session(configuration, user: "second-account")
    try restarted.save(replacement)
    #expect(try restarted.load() == replacement)
  }
  @Test func interruptedSaveMissingFenceAndLockedKeychainFailClosed() throws {
    let configuration = try config()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let keychain = FaultKeychain()
    let store = KeychainSessionStore(
      configuration: configuration, keychain: keychain, directory: directory)
    #expect(try store.load() == nil)
    try store.save(session(configuration))
    keychain.state.withLock { $0.failSave = true }
    #expect(throws: KeychainError.self) {
      try store.save(session(configuration, user: "second-account"))
    }
    #expect(try store.load() == nil)
    keychain.state.withLock { $0.failSave = false }
    try store.save(session(configuration))
    keychain.state.withLock { $0.failLoad = true }
    #expect(throws: KeychainError(status: errSecInteractionNotAllowed)) { try store.load() }
    keychain.state.withLock { $0.failLoad = false }
    try FileManager.default.removeItem(at: directory)
    #expect(try store.load() == nil)
    #expect(keychain.state.withLock { !$0.values.isEmpty })
  }
  @Test func partitionsAndPublicFenceContainNoCredentials() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let keychain = FaultKeychain()
    let stage = try config()
    let prod = try config("prod.example.invalid")
    let other = try config(app: "other-app")
    let a = KeychainSessionStore(configuration: stage, keychain: keychain, directory: directory)
    let b = KeychainSessionStore(configuration: prod, keychain: keychain, directory: directory)
    let c = KeychainSessionStore(configuration: other, keychain: keychain, directory: directory)
    try a.save(session(stage))
    try b.save(session(prod))
    try c.save(session(other))
    #expect(throws: MMGTError.sessionChanged) { try a.save(session(other)) }
    try a.clear()
    #expect(try a.load() == nil)
    #expect(try b.load() == session(prod))
    #expect(try c.load() == session(other))
    for url in try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    {
      let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
      #expect(Set(json?.keys.map { $0 } ?? []) == ["generation", "active"])
    }
    #expect(
      try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    )
  }
}
