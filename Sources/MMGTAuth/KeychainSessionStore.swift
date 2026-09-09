import Foundation
import Security
import CryptoKit
import MMGTCore

public struct PersistedSession: Codable, Sendable, Equatable {
    public let identity: AccountIdentity
    public let tokens: AuthTokens
    public init(identity: AccountIdentity, tokens: AuthTokens) { self.identity = identity; self.tokens = tokens }
}

/// Synchronous, atomic operations ensure persistence cannot outlive an actor's session-generation check.
public protocol SessionStore: Sendable {
    func load() throws -> PersistedSession?
    func save(_ session: PersistedSession) throws
    func clear() throws
}

public struct KeychainError: Error, Sendable, Equatable { public let status: OSStatus }

public final class KeychainSessionStore: SessionStore, Sendable {
    private let configuration: ServiceConfiguration
    private let key: String
    public init(configuration: ServiceConfiguration) {
        self.configuration = configuration
        key = SHA256.hash(data: Data(configuration.storagePartition.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.mmgt-cloud.sdk.auth",
         kSecAttrAccount as String: key,
         kSecAttrSynchronizable as String: false]
    }
    public func load() throws -> PersistedSession? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data else { throw MMGTError.invalidResponse("Invalid stored session") }
        let value = try JSONDecoder().decode(PersistedSession.self, from: data)
        guard value.identity.environment == configuration.storagePartition, value.identity.appID == configuration.appID else { throw MMGTError.sessionChanged }
        return value
    }
    public func save(_ session: PersistedSession) throws {
        guard session.identity.environment == configuration.storagePartition, session.identity.appID == configuration.appID else { throw MMGTError.sessionChanged }
        let update: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(session), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(update, uniquingKeysWith: { _, value in value }) as CFDictionary, nil) }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
    public func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
