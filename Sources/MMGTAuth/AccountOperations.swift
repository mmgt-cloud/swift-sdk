import Foundation
import MMGTCore

/// A short-lived proof issued after authenticating again for an account change.
public struct ReauthenticationProof: Codable, Sendable, Equatable, CustomStringConvertible {
  public let token: String
  public let expiresIn: Int
  public init(token: String, expiresIn: Int) {
    self.token = token
    self.expiresIn = expiresIn
  }
  enum CodingKeys: String, CodingKey {
    case token = "reauth_token"
    case expiresIn = "expires_in"
  }
  public var description: String { "ReauthenticationProof(<redacted>)" }
}

public struct MergeOptions: Codable, Sendable, Equatable {
  public let provider: String
  public let email: String?
  public let maskedEmail: String
  public let hasPassword: Bool
  public let linkedProviders: [String]
  enum CodingKeys: String, CodingKey {
    case provider, email
    case maskedEmail = "masked_email"
    case hasPassword = "has_password"
    case linkedProviders = "linked_providers"
  }
}

extension AuthClient {
  /// Begin a fresh assertion after registering a passkey. Setup credentials are accepted.
  public func beginPasskeyEnrollment() async throws -> JSONValue {
    let result: JSONValue = try await http.request(
      path: ["2fa", "passkey", "setup", "begin"], method: "POST")
    guard let options = result["options"] else {
      throw MMGTError.invalidResponse("Missing WebAuthn options")
    }
    return options
  }
  public func requestLoginCode(email: String) async throws -> MessageResponse {
    try await http.request(
      path: ["login", "otp", "start"], method: "POST", body: ["email": .string(email)],
      authenticated: false)
  }
  public func resendLoginCode(email: String) async throws -> MessageResponse {
    try await http.request(
      path: ["login", "otp", "resend"], method: "POST", body: ["email": .string(email)],
      authenticated: false)
  }
  public func verifyLoginCode(email: String, code: String) async throws -> LoginResult {
    try LoginResult.parse(
      await http.request(
        JSONValue.self, path: ["login", "otp", "verify"], method: "POST",
        body: ["email": .string(email), "code": .string(code)], authenticated: false),
      setupMessage: true)
  }
  public func startRegistrationWithCode(input: RegisterRequest) async throws -> MessageResponse {
    try await http.request(
      path: ["register", "otp", "start"], method: "POST", body: .encoding(input),
      authenticated: false)
  }
  public func resendRegistrationCode(email: String) async throws -> MessageResponse {
    try await http.request(
      path: ["register", "otp", "resend"], method: "POST", body: ["email": .string(email)],
      authenticated: false)
  }
  public func verifyRegistrationCode(email: String, code: String) async throws -> LoginResult {
    try LoginResult.parse(
      await http.request(
        JSONValue.self, path: ["register", "otp", "verify"], method: "POST",
        body: ["email": .string(email), "code": .string(code)], authenticated: false),
      setupMessage: true)
  }
  public func mergeOptions(token: String) async throws -> MergeOptions {
    try await http.request(
      path: ["merge", "options"], query: [.init(name: "merge_token", value: token)],
      authenticated: false)
  }
  /// Call after signing in to the existing account. The backend verifies account ownership.
  public func linkPendingAccount(mergeToken: String) async throws -> MessageResponse {
    try await http.request(
      path: ["merge", "link-authenticated"], method: "POST",
      body: ["merge_token": .string(mergeToken)])
  }
  public func reauthenticateWithPassword(currentPassword: String) async throws
    -> ReauthenticationProof
  {
    try await http.request(
      path: ["profile", "reauth", "password"], method: "POST",
      body: ["current_password": .string(currentPassword)])
  }
  public func beginPasskeyReauthentication() async throws -> JSONValue {
    let result: JSONValue = try await http.request(
      path: ["profile", "reauth", "passkey", "begin"], method: "POST")
    guard let options = result["options"] else {
      throw MMGTError.invalidResponse("Missing WebAuthn options")
    }
    return options
  }
  public func finishPasskeyReauthentication(credential: JSONValue) async throws
    -> ReauthenticationProof
  {
    try await http.request(
      path: ["profile", "reauth", "passkey", "finish"], method: "POST",
      body: ["credential": credential])
  }
  public func startEmailChange(newEmail: String, proof: ReauthenticationProof) async throws
    -> MessageResponse
  {
    try await http.request(
      path: ["profile", "email", "change", "start"], method: "POST",
      body: ["new_email": .string(newEmail), "reauth_token": .string(proof.token)])
  }
  public func cancelEmailChange() async throws -> MessageResponse {
    try await http.request(path: ["profile", "email", "change"], method: "DELETE")
  }
  /// Successful confirmation invalidates server sessions. Sign out locally and sign in again.
  public func confirmEmailChange(token: String) async throws -> MessageResponse {
    try await http.request(
      path: ["profile", "email", "change", "confirm"], method: "POST",
      body: ["token": .string(token)], authenticated: false)
  }
}
