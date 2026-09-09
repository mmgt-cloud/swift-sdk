import CryptoKit
import Foundation
import MMGTCore
import Security

public struct PersistedSession: Codable, Sendable, Equatable {
  public let identity: AccountIdentity
  public let tokens: AuthTokens
  public init(identity: AccountIdentity, tokens: AuthTokens) {
    self.identity = identity
    self.tokens = tokens
  }
}

/// Synchronous, atomic operations ensure persistence cannot outlive an actor's session-generation check.
public protocol SessionStore: Sendable {
  func load() throws -> PersistedSession?
  func save(_ session: PersistedSession) throws
  func clear() throws
}

public struct KeychainError: Error, Sendable, Equatable { public let status: OSStatus }

// Internal seam keeps Security types out of public API and permits deterministic
// locked-Keychain and interrupted-write tests.
protocol KeychainDataAccess: Sendable {
  func load(key: String) throws -> Data?
  func save(_ data: Data, key: String) throws
  func clear(key: String) throws
}

struct SystemKeychainDataAccess: KeychainDataAccess {
  private func query(_ key: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.mmgt-cloud.sdk.auth",
      kSecAttrAccount as String: key,
      kSecAttrSynchronizable as String: false,
    ]
  }
  func load(key: String) throws -> Data? {
    var request = query(key)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainError(status: status) }
    guard let data = result as? Data else {
      throw MMGTError.invalidResponse("Invalid stored session")
    }
    return data
  }
  func save(_ data: Data, key: String) throws {
    let update: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    var status = SecItemUpdate(query(key) as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(
        query(key).merging(update, uniquingKeysWith: { _, value in value }) as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw KeychainError(status: status) }
  }
  func clear(key: String) throws {
    let status = SecItemDelete(query(key) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError(status: status)
    }
  }
}

/// Keychain credentials require a matching local, backup-excluded activation fence.
/// Logout invalidates that fence before attempting a potentially unavailable Keychain.
/// Share one AuthSession owner for each application/environment partition.
public final class KeychainSessionStore: SessionStore, Sendable {
  private static let lock = NSLock()
  private let configuration: ServiceConfiguration
  private let key: String
  private let keychain: any KeychainDataAccess
  private let directory: URL?
  private struct Fence: Codable {
    let generation: UUID
    let active: Bool
  }
  private struct Envelope: Codable {
    let generation: UUID
    let session: PersistedSession
  }

  public convenience init(configuration: ServiceConfiguration) {
    self.init(
      configuration: configuration, keychain: SystemKeychainDataAccess(),
      directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first?.appendingPathComponent("MMGT/AuthSessionFences", isDirectory: true))
  }
  init(configuration: ServiceConfiguration, keychain: any KeychainDataAccess, directory: URL?) {
    self.configuration = configuration
    self.keychain = keychain
    self.directory = directory
    key = SHA256.hash(data: Data(configuration.storagePartition.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
  }
  private func fenceURL() throws -> URL {
    guard let directory, directory.isFileURL else {
      throw MMGTError.invalidConfiguration("Session fence directory unavailable")
    }
    return directory.appendingPathComponent(key + ".json")
  }
  private func writeFence(_ fence: Fence) throws {
    let url = try fenceURL()
    var parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: parent, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try parent.setResourceValues(values)
    try JSONEncoder().encode(fence).write(
      to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }
  public func load() throws -> PersistedSession? {
    try Self.lock.withLock {
      let data: Data
      do { data = try Data(contentsOf: fenceURL()) } catch let error as CocoaError
        where error.code == .fileReadNoSuchFile
      { return nil }
      let fence = try JSONDecoder().decode(Fence.self, from: data)
      guard fence.active else { return nil }
      guard let data = try keychain.load(key: key) else { return nil }
      let value = try JSONDecoder().decode(Envelope.self, from: data)
      guard value.generation == fence.generation else { return nil }
      guard value.session.identity.environment == configuration.storagePartition,
        value.session.identity.appID == configuration.appID
      else { throw MMGTError.sessionChanged }
      return value.session
    }
  }
  public func save(_ session: PersistedSession) throws {
    try Self.lock.withLock {
      guard session.identity.environment == configuration.storagePartition,
        session.identity.appID == configuration.appID
      else { throw MMGTError.sessionChanged }
      let generation = UUID()
      // Any interruption or failed write leaves the old credentials ineligible.
      try writeFence(Fence(generation: generation, active: false))
      try keychain.save(
        try JSONEncoder().encode(Envelope(generation: generation, session: session)), key: key)
      try writeFence(Fence(generation: generation, active: true))
    }
  }
  public func clear() throws {
    try Self.lock.withLock {
      try writeFence(Fence(generation: UUID(), active: false))
      try keychain.clear(key: key)
    }
  }
}
