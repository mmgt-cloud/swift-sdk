import CryptoKit
import Foundation
import MMGTCore

struct TrustedDeviceCredential: Codable, Sendable {
  let token: String
  let expiresAt: Date
}

protocol TrustedDeviceStore: Sendable {
  func load() throws -> TrustedDeviceCredential?
  func save(_ credential: TrustedDeviceCredential) throws
  func clear() throws
}

// Separate from the session: remembering a device intentionally survives logout.
// The backup-excluded fence prevents an old Keychain entry from surviving forget
// or reinstall, including when protected Keychain data is unavailable.
final class KeychainTrustedDeviceStore: TrustedDeviceStore, Sendable {
  private static let lock = NSLock()
  private let key: String
  private let keychain: any KeychainDataAccess
  private let directory: URL?
  private struct Fence: Codable {
    let generation: UUID
    let active: Bool
  }
  private struct Envelope: Codable {
    let generation: UUID
    let credential: TrustedDeviceCredential
  }

  init(
    configuration: ServiceConfiguration, email: String,
    keychain: any KeychainDataAccess = SystemKeychainDataAccess(), directory: URL? = nil
  ) {
    let partition = ["trusted-device-v1", configuration.storagePartition, email]
    let data = partition.reduce(into: Data()) { result, part in
      result.append(Data("\(part.utf8.count):".utf8))
      result.append(Data(part.utf8))
    }
    key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    self.keychain = keychain
    self.directory =
      directory
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first?.appendingPathComponent("MMGT/TrustedDeviceFences", isDirectory: true)
  }
  private func fenceURL() throws -> URL {
    guard let directory, directory.isFileURL else {
      throw MMGTError.invalidConfiguration("Trusted-device fence directory unavailable")
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
  func load() throws -> TrustedDeviceCredential? {
    try Self.lock.withLock {
      let data: Data
      do { data = try Data(contentsOf: fenceURL()) } catch let error as CocoaError
        where error.code == .fileReadNoSuchFile
      { return nil }
      let fence = try JSONDecoder().decode(Fence.self, from: data)
      guard fence.active, let data = try keychain.load(key: key) else { return nil }
      let envelope = try JSONDecoder().decode(Envelope.self, from: data)
      return envelope.generation == fence.generation ? envelope.credential : nil
    }
  }
  func save(_ credential: TrustedDeviceCredential) throws {
    try Self.lock.withLock {
      let generation = UUID()
      try writeFence(Fence(generation: generation, active: false))
      try keychain.save(
        try JSONEncoder().encode(Envelope(generation: generation, credential: credential)), key: key
      )
      try writeFence(Fence(generation: generation, active: true))
    }
  }
  func clear() throws {
    try Self.lock.withLock {
      try writeFence(Fence(generation: UUID(), active: false))
      try keychain.clear(key: key)
    }
  }
}

/// Opt-in password/MFA trusted-device support, bound to one Auth environment,
/// application and email. Use the same transport for password and MFA requests.
/// It never uses the shared cookie jar or sends trust to other services/routes.
public actor TrustedDeviceTransport: HTTPTransport {
  public nonisolated let configuration: ServiceConfiguration
  private let email: String
  private let underlying: any HTTPTransport
  private let store: any TrustedDeviceStore
  private var generation = UUID()
  private var challenge: String?

  public init(
    configuration: ServiceConfiguration, email: String,
    transport: any HTTPTransport = URLSessionTransport()
  ) throws {
    let normalized = try Self.normalize(email)
    self.configuration = configuration
    self.email = normalized
    underlying = transport
    store = KeychainTrustedDeviceStore(configuration: configuration, email: normalized)
  }
  init(
    configuration: ServiceConfiguration, email: String,
    transport: any HTTPTransport, store: any TrustedDeviceStore
  ) throws {
    self.configuration = configuration
    self.email = try Self.normalize(email)
    underlying = transport
    self.store = store
  }
  private nonisolated static func normalize(_ email: String) throws -> String {
    let result = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard result.contains("@"), !result.contains(where: { $0.isWhitespace || $0.isNewline }),
      !result.contains("\0")
    else {
      throw MMGTError.invalidConfiguration("A single account email is required for device trust")
    }
    return result
  }
  /// Whether this installation has an unexpired local credential. The server can
  /// still revoke it or require MFA; this property does not establish access.
  public func isRemembered() throws -> Bool {
    guard let credential = try store.load() else { return false }
    return credential.expiresAt > Date()
  }
  /// Forget local trust and invalidate an in-flight MFA response. Revoke the
  /// corresponding server device separately when revocation is also intended.
  public func forget() throws {
    generation = UUID()
    challenge = nil
    try store.clear()
  }
  public func send(_ request: URLRequest) async throws -> HTTPResponse {
    try Task.checkCancellation()
    guard let url = request.url,
      let root = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false),
      let target = URLComponents(url: url, resolvingAgainstBaseURL: false),
      target.scheme == "https", target.host?.lowercased() == root.host?.lowercased(),
      (target.port ?? 443) == (root.port ?? 443), target.user == nil, target.password == nil,
      target.fragment == nil,
      request.value(forHTTPHeaderField: "X-App-ID") == configuration.appID,
      request.value(forHTTPHeaderField: "Cookie") == nil
    else { throw MMGTError.sessionChanged }
    let loginURL = try configuration.url(["login"])
    let verifyURL = try configuration.url(["2fa", "login-verify"])
    let rootPath = configuration.baseURL.path.trimmingCharacters(
      in: CharacterSet(charactersIn: "/"))
    guard target.path.hasPrefix("/" + (rootPath.isEmpty ? "" : rootPath + "/")) else {
      throw MMGTError.sessionChanged
    }
    let isLogin = url == loginURL && request.httpMethod == "POST"
    let isVerification = url == verifyURL && request.httpMethod == "POST"
    var outgoing = request
    var remember = false
    if isLogin || isVerification {
      guard let data = request.httpBody else {
        throw MMGTError.invalidResponse("Missing authentication body")
      }
      let body = try JSONDecoder().decode(JSONValue.self, from: data)
      if isLogin {
        guard let requested = body["email"]?.string, try Self.normalize(requested) == email else {
          throw MMGTError.sessionChanged
        }
        generation = UUID()
        challenge = nil
        if let credential = try store.load(), credential.expiresAt > Date() {
          guard Self.validToken(credential.token) else {
            throw MMGTError.invalidResponse("Invalid stored device trust")
          }
          outgoing.setValue("trusted_device=" + credential.token, forHTTPHeaderField: "Cookie")
        }
      } else {
        remember = body["remember_device"]?.bool == true
        if remember {
          guard let pending = challenge, body["temp_token"]?.string == pending else {
            throw MMGTError.invalidConfiguration(
              "Device trust requires this account's fresh password/MFA challenge")
          }
          challenge = nil
        }
      }
    }
    let expected = generation
    let response = try await underlying.send(outgoing)
    try Task.checkCancellation()
    if isLogin || remember {
      guard generation == expected else { throw MMGTError.sessionChanged }
      if (200..<300).contains(response.status) {
        let result = try LoginResult.parse(
          JSONDecoder().decode(JSONValue.self, from: response.data), setupMessage: isLogin)
        if isLogin, case .requiresTwoFactor(let token, _, _) = result { challenge = token }
        if remember, case .authenticated = result, let header = response.headers["set-cookie"] {
          let cookies = HTTPCookie.cookies(
            withResponseHeaderFields: ["Set-Cookie": header], for: url
          )
          .filter { $0.name == "trusted_device" }
          guard cookies.count == 1, let cookie = cookies.first, cookie.isSecure, cookie.isHTTPOnly,
            cookie.domain.lowercased() == target.host?.lowercased(), cookie.path == "/",
            Self.validToken(cookie.value), let expiresAt = cookie.expiresDate, expiresAt > Date()
          else { throw MMGTError.invalidResponse("Invalid trusted-device cookie") }
          try store.save(TrustedDeviceCredential(token: cookie.value, expiresAt: expiresAt))
        }
      }
    }
    if request.httpMethod == "DELETE", (200..<300).contains(response.status),
      url == (try configuration.url(["2fa", "trusted-devices"]))
    {
      try forget()
    }
    return response
  }
  private nonisolated static func validToken(_ token: String) -> Bool {
    token.utf8.count == 64
      && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}
