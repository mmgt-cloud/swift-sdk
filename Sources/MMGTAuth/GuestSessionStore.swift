import CryptoKit
import Foundation
import MMGTCore
import Security
import Synchronization

public struct GuestCredentials: Codable, Sendable, Equatable {
  public let guestID: String
  public let appID: String
  public let issuer: String
  public let purpose: String
  public let accessToken: String
  public let expiresAt: String
  public let idleExpiresAt: String
  public init(
    guestID: String, appID: String, issuer: String, purpose: String = "ai", accessToken: String,
    expiresAt: String, idleExpiresAt: String
  ) {
    self.guestID = guestID
    self.appID = appID
    self.issuer = issuer
    self.purpose = purpose
    self.accessToken = accessToken
    self.expiresAt = expiresAt
    self.idleExpiresAt = idleExpiresAt
  }
  enum CodingKeys: String, CodingKey {
    case guestID = "guest_id"
    case appID = "app_id"
    case issuer, purpose
    case accessToken = "access_token"
    case expiresAt = "expires_at"
    case idleExpiresAt = "idle_expires_at"
  }
}

public enum GuestSessionPhase: String, Codable, Sendable { case active, revoking, revoked, expired }
public struct GuestStoredSession: Codable, Sendable, Equatable {
  public var revision: String
  public var phase: GuestSessionPhase
  /// A credential, never a public installation identifier. Do not log this value.
  public var renewalSecret: String?
  public var credentials: GuestCredentials?
  public init(
    revision: String = UUID().uuidString, phase: GuestSessionPhase, renewalSecret: String? = nil,
    credentials: GuestCredentials? = nil
  ) {
    self.revision = revision
    self.phase = phase
    self.renewalSecret = renewalSecret
    self.credentials = credentials
  }
}

/// Operations are synchronous so persistence cannot outlive an actor generation check.
/// CAS must be atomic across every instance/process sharing this store.
public protocol GuestSessionStore: Sendable {
  func load(partition: String) throws -> GuestStoredSession?
  func compareAndSwap(partition: String, expectedRevision: String?, next: GuestStoredSession) throws
    -> Bool
}

/// Explicitly volatile storage. The default GuestSession uses Keychain instead.
public final class MemoryGuestSessionStore: GuestSessionStore, Sendable {
  private let rows = Mutex<[String: GuestStoredSession]>([:])
  public init() {}
  public func load(partition: String) -> GuestStoredSession? { rows.withLock { $0[partition] } }
  public func compareAndSwap(partition: String, expectedRevision: String?, next: GuestStoredSession)
    throws -> Bool
  {
    guard !next.revision.isEmpty, next.revision != expectedRevision else {
      throw MMGTError.invalidConfiguration("A new guest storage revision is required")
    }
    return rows.withLock { values in
      guard values[partition]?.revision == expectedRevision else { return false }
      values[partition] = next
      return true
    }
  }
}

/// Uses Security's conditional update, not a process-only lock. No access group or iCloud sharing.
public struct KeychainGuestSessionStore: GuestSessionStore, Sendable {
  public init() {}
  private func query(_ partition: String) -> [String: Any] {
    let key = SHA256.hash(data: Data(partition.utf8)).map { String(format: "%02x", $0) }.joined()
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.mmgt-cloud.sdk.guest-ai",
      kSecAttrAccount as String: key,
      kSecAttrSynchronizable as String: false,
    ]
  }
  public func load(partition: String) throws -> GuestStoredSession? {
    var query = query(partition)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var output: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &output)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainError(status: status) }
    guard let data = output as? Data else {
      throw MMGTError.invalidResponse("Invalid stored guest session")
    }
    return try JSONDecoder().decode(GuestStoredSession.self, from: data)
  }
  public func compareAndSwap(partition: String, expectedRevision: String?, next: GuestStoredSession)
    throws -> Bool
  {
    guard !next.revision.isEmpty, next.revision != expectedRevision else {
      throw MMGTError.invalidConfiguration("A new guest storage revision is required")
    }
    var query = query(partition)
    let values: [String: Any] = [
      kSecValueData as String: try JSONEncoder().encode(next),
      kSecAttrGeneric as String: Data(next.revision.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let status: OSStatus
    if let expectedRevision {
      query[kSecAttrGeneric as String] = Data(expectedRevision.utf8)
      status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
      if status == errSecItemNotFound { return false }
    } else {
      status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
      if status == errSecDuplicateItem { return false }
    }
    guard status == errSecSuccess else { throw KeychainError(status: status) }
    return true
  }
  // Test cleanup only. Runtime revocation retains a terminal tombstone to fence delayed requests.
  func removeTestPartition(_ partition: String) throws {
    let status = SecItemDelete(query(partition) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError(status: status)
    }
  }
}
