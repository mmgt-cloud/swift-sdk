import Foundation
import MMGTCore

public struct AuthTokens: Codable, Sendable, Equatable, CustomStringConvertible {
  public let accessToken: String
  public let refreshToken: String
  public init(accessToken: String, refreshToken: String) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
  }
  public var description: String { "AuthTokens(<redacted>)" }
}

public enum LoginResult: Sendable, Equatable, CustomStringConvertible {
  case authenticated(AuthTokens)
  case requiresTwoFactor(tempToken: String, method: String, message: String?)
  case requiresTwoFactorSetup(AuthTokens, message: String?)
  case passwordExpired

  public var description: String {
    switch self {
    case .authenticated: "LoginResult.authenticated(<redacted>)"
    case .requiresTwoFactor: "LoginResult.requiresTwoFactor(<redacted>)"
    case .requiresTwoFactorSetup: "LoginResult.requiresTwoFactorSetup(<redacted>)"
    case .passwordExpired: "LoginResult.passwordExpired"
    }
  }

  static func parse(_ response: JSONValue, setupMessage: Bool = false) throws -> Self {
    if response["requires_2fa"]?.bool == true {
      guard response["access_token"] == nil, response["refresh_token"] == nil,
        response["requires_2fa_setup"]?.bool != true,
        response["password_expired"]?.bool != true,
        let temp = response["temp_token"]?.string, !temp.isEmpty,
        let method = response["method"]?.string, !method.isEmpty
      else { throw MMGTError.invalidResponse("Incomplete or contradictory MFA result") }
      return .requiresTwoFactor(
        tempToken: temp, method: method, message: response["message"]?.string)
    }
    if response["password_expired"]?.bool == true {
      guard (response["access_token"]?.string ?? "").isEmpty,
        (response["refresh_token"]?.string ?? "").isEmpty
      else { throw MMGTError.invalidResponse("Expired password response included session tokens") }
      return .passwordExpired
    }
    if let access = response["access_token"]?.string, !access.isEmpty,
      let refresh = response["refresh_token"]?.string, !refresh.isEmpty
    {
      let tokens = AuthTokens(accessToken: access, refreshToken: refresh)
      if response["requires_2fa_setup"]?.bool == true
        || (setupMessage && response["message"]?.string != nil && response["requires_2fa"] == nil)
      {
        return .requiresTwoFactorSetup(tokens, message: response["message"]?.string)
      }
      return .authenticated(tokens)
    }
    throw MMGTError.invalidResponse("Unrecognized login result")
  }
}

/// Stateless endpoint client. Use AuthSession to persist tokens and own refresh/logout.
public struct AuthClient: Sendable {
  let http: HTTPClient
  public let configuration: ServiceConfiguration
  public init(
    configuration: ServiceConfiguration, tokenProvider: AccessTokenProvider? = nil,
    transport: any HTTPTransport = URLSessionTransport()
  ) {
    self.configuration = configuration
    http = HTTPClient(
      configuration: configuration, tokenProvider: tokenProvider, transport: transport)
  }
  public func getAppConfig() async throws -> AppLoginConfigResponse {
    try await http.request(path: ["app-config", configuration.appID], authenticated: false)
  }
  public func login(input: LoginRequest) async throws -> LoginResult {
    try LoginResult.parse(
      await http.request(
        JSONValue.self, path: ["login"], method: "POST", body: .encoding(input),
        authenticated: false), setupMessage: true)
  }
  public func verifyMagicLink(input: MagicLinkVerifyRequest) async throws -> LoginResult {
    if let appID = input.appId, appID != configuration.appID { throw MMGTError.sessionChanged }
    return try LoginResult.parse(
      await http.request(
        JSONValue.self, path: ["magic-link", "verify"], method: "POST", body: .encoding(input),
        authenticated: false), setupMessage: true)
  }
  public func confirmMerge(input: MergeAccountRequest) async throws -> LoginResult {
    try LoginResult.parse(
      await http.request(
        JSONValue.self, path: ["merge", "confirm"], method: "POST", body: .encoding(input),
        authenticated: false))
  }
  public func verify2FALogin(input: TwoFALoginRequest) async throws -> LoginResult {
    try LoginResult.parse(
      await http.request(
        JSONValue.self, path: ["2fa", "login-verify"], method: "POST", body: .encoding(input),
        authenticated: false))
  }
  public func refreshToken(_ token: String) async throws -> AuthTokens {
    let result = try LoginResult.parse(
      await http.request(
        JSONValue.self, path: ["refresh-token"], method: "POST",
        body: ["refresh_token": .string(token)], authenticated: false))
    guard case .authenticated(let tokens) = result else {
      throw MMGTError.invalidResponse("Refresh did not return tokens")
    }
    return tokens
  }
  public func logout(tokens: AuthTokens) async throws -> MessageResponse {
    try await http.request(
      path: ["logout"], method: "POST",
      body: [
        "access_token": .string(tokens.accessToken), "refresh_token": .string(tokens.refreshToken),
      ])
  }
  public func deleteAccount(input: DeleteAccountRequest) async throws -> MessageResponse {
    guard input.confirmDeletion else {
      throw MMGTError.invalidConfiguration("Account deletion requires confirmation")
    }
    return try await http.request(path: ["profile"], method: "DELETE", body: .encoding(input))
  }
  public func beginPasskeyRegistration() async throws -> JSONValue {
    let response: JSONValue = try await http.request(
      path: ["passkey", "register", "begin"], method: "POST")
    guard let options = response["options"] else {
      throw MMGTError.invalidResponse("Missing WebAuthn options")
    }
    return options
  }
  public func beginPasskey2FA(tempToken: String) async throws -> JSONValue {
    let response: JSONValue = try await http.request(
      path: ["2fa", "passkey", "begin"], method: "POST", body: ["temp_token": .string(tempToken)],
      authenticated: false)
    guard let options = response["options"] else {
      throw MMGTError.invalidResponse("Missing WebAuthn options")
    }
    return options
  }
  public func finishPasskey2FA(tempToken: String, credential: JSONValue) async throws -> LoginResult
  {
    try LoginResult.parse(
      await http.request(
        JSONValue.self, path: ["2fa", "passkey", "finish"], method: "POST",
        body: ["temp_token": .string(tempToken), "credential": credential], authenticated: false))
  }
  public func finishPasswordlessLogin(sessionID: String, credential: JSONValue) async throws
    -> LoginResult
  {
    try LoginResult.parse(
      await http.request(
        JSONValue.self, path: ["passkey", "login", "finish"], method: "POST",
        body: ["session_id": .string(sessionID), "credential": credential], authenticated: false))
  }
  public func listActivityLogs(
    page: Int? = nil, limit: Int? = nil, eventType: String? = nil, startDate: String? = nil,
    endDate: String? = nil
  ) async throws -> ActivityLogListResponse {
    let query = [
      URLQueryItem(name: "page", value: page.map(String.init)),
      .init(name: "limit", value: limit.map(String.init)),
      .init(name: "event_type", value: eventType), .init(name: "start_date", value: startDate),
      .init(name: "end_date", value: endDate),
    ].filter { $0.value != nil }
    return try await http.request(path: ["activity-logs"], query: query)
  }
  public func exportActivityLogs(
    eventType: String? = nil, startDate: String? = nil, endDate: String? = nil
  ) async throws -> ActivityLogExportResponse {
    let query = [
      URLQueryItem(name: "format", value: "json"), .init(name: "event_type", value: eventType),
      .init(name: "start_date", value: startDate), .init(name: "end_date", value: endDate),
    ].filter { $0.value != nil }
    return try await http.request(path: ["activity-logs", "export"], query: query)
  }
  public func exportActivityCSV(
    eventType: String? = nil, startDate: String? = nil, endDate: String? = nil
  ) async throws -> String {
    let query = [
      URLQueryItem(name: "format", value: "csv"), .init(name: "event_type", value: eventType),
      .init(name: "start_date", value: startDate), .init(name: "end_date", value: endDate),
    ].filter { $0.value != nil }
    let data = try await http.send(path: ["activity-logs", "export"], query: query)
    guard let text = String(data: data, encoding: .utf8) else {
      throw MMGTError.invalidResponse("Invalid CSV encoding")
    }
    return text
  }
}
