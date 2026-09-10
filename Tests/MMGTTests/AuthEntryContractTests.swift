import Foundation
import MMGTAuth
import MMGTCore
import Testing

private enum AuthEntryOperation: String, CaseIterable, Sendable {
  case register, startRegistration, resendRegistration, verifyRegistration
  case startLogin, resendLogin, verifyLogin, login, refresh, logout
  case forgot, reset, verifyEmail, resendVerification, requestMagic, verifyMagic
}

@Suite struct AuthEntryContractTests {
  private let email = "synthetic@example.invalid"
  private let password = "synthetic-password"
  private let appID = "11111111-1111-4111-8111-111111111111"

  private func client(_ transport: RecordingTransport) throws -> AuthClient {
    AuthClient(
      configuration: try .init(
        baseURL: URL(string: "https://api.example.invalid/auth")!, appID: appID),
      tokenProvider: { "synthetic-access" }, transport: transport)
  }

  private func execute(_ operation: AuthEntryOperation, using sdk: AuthClient) async throws
    -> JSONValue
  {
    switch operation {
    case .register:
      return try .encoding(await sdk.register(input: .init(email: email, password: password)))
    case .startRegistration:
      return try .encoding(
        await sdk.startRegistrationWithCode(input: .init(email: email, password: password)))
    case .resendRegistration: return try .encoding(await sdk.resendRegistrationCode(email: email))
    case .startLogin: return try .encoding(await sdk.requestLoginCode(email: email))
    case .resendLogin: return try .encoding(await sdk.resendLoginCode(email: email))
    case .logout:
      return try .encoding(
        await sdk.logout(
          tokens: .init(accessToken: "synthetic-access", refreshToken: "synthetic-refresh")))
    case .forgot: return try .encoding(await sdk.forgotPassword(input: .init(email: email)))
    case .reset:
      return try .encoding(
        await sdk.resetPassword(input: .init(token: "synthetic-reset", newPassword: password)))
    case .verifyEmail: return try .encoding(await sdk.verifyEmail(token: "synthetic+/=&?#"))
    case .resendVerification:
      return try .encoding(await sdk.resendVerification(input: .init(email: email)))
    case .requestMagic: return try .encoding(await sdk.requestMagicLink(input: .init(email: email)))
    default:
      let tokens: AuthTokens
      if operation == .refresh {
        tokens = try await sdk.refreshToken("synthetic-refresh")
      } else {
        let result = try await authenticate(operation, using: sdk)
        guard case .authenticated(let value) = result else {
          throw MMGTError.invalidResponse("Expected synthetic complete session")
        }
        tokens = value
      }
      return [
        "access_token": .string(tokens.accessToken), "refresh_token": .string(tokens.refreshToken),
      ]
    }
  }

  private func authenticate(_ operation: AuthEntryOperation, using sdk: AuthClient) async throws
    -> LoginResult
  {
    switch operation {
    case .login:
      try await sdk.login(
        input: .init(email: email, password: password, captchaToken: "synthetic-captcha"))
    case .verifyRegistration: try await sdk.verifyRegistrationCode(email: email, code: "123456")
    case .verifyLogin: try await sdk.verifyLoginCode(email: email, code: "123456")
    case .verifyMagic:
      try await sdk.verifyMagicLink(input: .init(token: "synthetic-magic", appId: appID))
    default: throw MMGTError.invalidConfiguration("Not a login operation")
    }
  }

  @Test(arguments: AuthEntryOperation.allCases)
  private func publicEntryRoutesPreserveAppBodyAndAuthentication(_ operation: AuthEntryOperation)
    async throws
  {
    let fixtures = SharedWireContractTests()
    let path: String
    var method = "POST"
    var status = 200
    var body: JSONValue? = ["email": .string(email)]
    var wire: JSONValue = ["message": "Synthetic operation accepted"]
    switch operation {
    case .register, .startRegistration:
      path = operation == .register ? "register" : "register/otp/start"
      status = operation == .register ? 201 : 202
      body = ["email": .string(email), "password": .string(password)]
    case .resendRegistration: path = "register/otp/resend"
    case .startLogin:
      path = "login/otp/start"
      status = 202
    case .resendLogin: path = "login/otp/resend"
    case .verifyRegistration, .verifyLogin:
      path = operation == .verifyRegistration ? "register/otp/verify" : "login/otp/verify"
      body = ["email": .string(email), "code": "123456"]
      wire = try fixtures.decode("auth-login")
    case .login:
      path = "login"
      body = [
        "email": .string(email), "password": .string(password),
        "captcha_token": "synthetic-captcha",
      ]
      wire = try fixtures.decode("auth-login")
    case .refresh:
      path = "refresh-token"
      body = ["refresh_token": "synthetic-refresh"]
      wire = try fixtures.decode("auth-login")
    case .logout:
      path = "logout"
      body = ["access_token": "synthetic-access", "refresh_token": "synthetic-refresh"]
    case .forgot: path = "forgot-password"
    case .reset:
      path = "reset-password"
      body = ["token": "synthetic-reset", "new_password": .string(password)]
    case .verifyEmail:
      path = "verify-email"
      method = "GET"
      body = nil
    case .resendVerification: path = "resend-verification"
    case .requestMagic: path = "magic-link/request"
    case .verifyMagic:
      path = "magic-link/verify"
      body = ["token": "synthetic-magic", "app_id": .string(appID)]
      wire = try fixtures.decode("auth-login")
    }
    let transport = RecordingTransport([.init(data: try JSONEncoder().encode(wire), status: status)]
    )
    #expect(try await execute(operation, using: client(transport)) == wire)
    let sent = await transport.requests
    #expect(sent.count == 1)
    let request = try #require(sent.first)
    #expect(request.httpMethod == method && request.url?.path == "/auth/" + path)
    #expect(request.value(forHTTPHeaderField: "X-App-ID") == appID)
    #expect(
      request.value(forHTTPHeaderField: "Authorization")
        == (operation == .logout ? "Bearer synthetic-access" : nil))
    #expect(try request.httpBody.map { try JSONDecoder().decode(JSONValue.self, from: $0) } == body)
    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(
      query == (operation == .verifyEmail ? [.init(name: "token", value: "synthetic+/=&?#")] : []))
  }

  @Test(
    arguments: [AuthEntryOperation.login, .verifyLogin, .verifyRegistration, .verifyMagic],
    ["auth-mfa", "auth-enrollment", "auth-enrollmentlegacy"])
  private func primaryCredentialCannotBypassMFA(_ operation: AuthEntryOperation, _ fixture: String)
    async throws
  {
    let transport = RecordingTransport([
      .init(data: try SharedWireContractTests().data(fixture), status: 202)
    ])
    let result = try await authenticate(operation, using: client(transport))
    if fixture == "auth-mfa" {
      guard case .requiresTwoFactor(let token, let method, _) = result else {
        Issue.record("MFA was bypassed")
        return
      }
      #expect(token == "synthetic-temp" && method == "passkey")
    } else {
      guard case .requiresTwoFactorSetup(let tokens, _) = result else {
        Issue.record("Enrollment was bypassed")
        return
      }
      #expect(tokens.accessToken == "synthetic-enrollment-access")
    }
    #expect(await transport.requests.count == 1)
  }

  @Test func expiredPasswordAndRefreshEnrollmentCannotBecomeAuthenticated() async throws {
    let transport = RecordingTransport(
      try ["auth-passwordexpired", "auth-enrollment", "auth-mfa"].map {
        .init(data: try SharedWireContractTests().data($0), status: 200)
      })
    let sdk = try client(transport)
    #expect(try await authenticate(.login, using: sdk) == .passwordExpired)
    for _ in 0..<2 {
      await #expect(throws: MMGTError.self) { _ = try await sdk.refreshToken("synthetic-refresh") }
    }
    #expect(await transport.requests.count == 3)
  }

  @Test(arguments: ["auth-captcha", "auth-accountlocked"])
  func challengeErrorRetainsActionableFieldsWithoutRetry(_ fixture: String) async throws {
    let status = fixture == "auth-captcha" ? 403 : 423
    let wire: JSONValue = try SharedWireContractTests().decode(fixture)
    let transport = RecordingTransport([
      .init(
        data: try JSONEncoder().encode(wire), status: status,
        headers: ["X-Request-ID": "synthetic-request"])
    ])
    do {
      _ = try await authenticate(.login, using: client(transport))
      Issue.record("Expected authentication challenge error")
    } catch let error as APIError {
      #expect(
        error.status == status && error.body == wire && error.requestID == "synthetic-request")
      #expect(error.body?["retry_after"] != nil)
    }
    #expect(await transport.requests.count == 1)
  }

  @Test(
    arguments: [
      AuthEntryOperation.register, .verifyRegistration, .verifyLogin, .login, .refresh, .logout,
      .reset, .verifyMagic,
    ], [429, 503])
  private func uncertainAccountWriteNeverRetries(_ operation: AuthEntryOperation, _ status: Int)
    async throws
  {
    let transport = RecordingTransport([
      .init(data: Data(#"{"error":"Synthetic rejection"}"#.utf8), status: status)
    ])
    await #expect(throws: APIError.self) {
      _ = try await execute(operation, using: client(transport))
    }
    #expect(await transport.requests.count == 1)
  }

  @Test func foreignMagicLinkFailsBeforeSendingTheOneTimeToken() async throws {
    let transport = RecordingTransport([])
    await #expect(throws: MMGTError.sessionChanged) {
      _ = try await client(transport).verifyMagicLink(
        input: .init(token: "synthetic-one-time", appId: "foreign"))
    }
    #expect(await transport.requests.isEmpty)
  }
}
