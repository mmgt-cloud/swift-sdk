import Foundation
import MMGTAuth
import MMGTCore
import Testing

@Suite struct AuthAccountHTTPTests {
  struct Endpoint: Sendable {
    let name, method, path: String
    var authenticated = true
    var body: JSONValue? = nil
    var fixture: String? = nil
    var options = false
    var login = false
  }
  static let credential: JSONValue = [
    "id": "AQID_w", "rawId": "AQID_w", "type": "public-key",
    "response": [
      "clientDataJSON": "AAECA_7_", "authenticatorData": "AQID_w", "signature": "BAUG",
      "userHandle": .null,
    ],
    "clientExtensionResults": [:],
  ]
  static let endpoints: [Endpoint] = [
    .init(
      name: "getAppConfig", method: "GET", path: "app-config/11111111-1111-4111-8111-111111111111",
      authenticated: false, fixture: "auth-config"),
    .init(
      name: "updateEmail", method: "PUT", path: "profile/email",
      body: ["email": "new@example.invalid", "password": "synthetic-old"]),
    .init(
      name: "updatePassword", method: "PUT", path: "profile/password",
      body: ["current_password": "synthetic-old", "new_password": "synthetic-new"]),
    .init(
      name: "setPassword", method: "POST", path: "profile/set-password",
      body: ["new_password": "synthetic-new"]),
    .init(
      name: "deleteAccount", method: "DELETE", path: "profile",
      body: ["password": "synthetic-old", "confirm_deletion": true]),
    .init(name: "validateToken", method: "GET", path: "validate", fixture: "auth-validated"),
    .init(
      name: "confirmMerge", method: "POST", path: "merge/confirm", authenticated: false,
      body: ["merge_token": "synthetic-merge", "password": "synthetic-old"], fixture: "auth-merge",
      login: true),
    .init(
      name: "unlinkSocialAccount", method: "DELETE",
      path: "profile/social-accounts/33333333-3333-4333-8333-333333333333"),
    .init(
      name: "verify2FALogin", method: "POST", path: "2fa/login-verify", authenticated: false,
      body: [
        "temp_token": "synthetic-temp", "recovery_code": "synthetic-recovery",
        "remember_device": false,
      ], fixture: "auth-login", login: true),
    .init(
      name: "beginPasskeyRegistration", method: "POST", path: "passkey/register/begin",
      fixture: "auth-creation", options: true),
    .init(
      name: "finishPasskeyRegistration", method: "POST", path: "passkey/register/finish",
      body: ["name": "Synthetic key", "credential": credential]),
    .init(
      name: "beginPasskey2FA", method: "POST", path: "2fa/passkey/begin", authenticated: false,
      body: ["temp_token": "synthetic-temp"], fixture: "auth-assertion", options: true),
    .init(
      name: "beginPasskeyEnrollment", method: "POST", path: "2fa/passkey/setup/begin",
      fixture: "auth-assertion", options: true),
    .init(
      name: "finishPasskeyEnrollment", method: "POST", path: "2fa/passkey/setup/finish",
      body: ["credential": credential], fixture: "auth-enabled"),
    .init(
      name: "finishPasskey2FA", method: "POST", path: "2fa/passkey/finish", authenticated: false,
      body: ["temp_token": "synthetic-temp", "credential": credential], fixture: "auth-login",
      login: true),
    .init(
      name: "beginPasswordlessLogin", method: "POST", path: "passkey/login/begin",
      authenticated: false, fixture: "auth-passkeylogin"),
    .init(
      name: "finishPasswordlessLogin", method: "POST", path: "passkey/login/finish",
      authenticated: false, body: ["session_id": "synthetic-session", "credential": credential],
      fixture: "auth-login", login: true),
    .init(name: "listPasskeys", method: "GET", path: "passkeys", fixture: "auth-passkeys"),
    .init(
      name: "renamePasskey", method: "PUT", path: "passkeys/33333333-3333-4333-8333-333333333333",
      body: ["name": "Synthetic key"]),
    .init(
      name: "deletePasskey", method: "DELETE", path: "passkeys/33333333-3333-4333-8333-333333333333"
    ),
    .init(
      name: "revokeSession", method: "DELETE", path: "sessions/33333333-3333-4333-8333-333333333333"
    ),
    .init(name: "revokeOtherSessions", method: "DELETE", path: "sessions"),
  ]

  func call(_ name: String, client: AuthClient) async throws -> JSONValue {
    let id = "33333333-3333-4333-8333-333333333333"
    switch name {
    case "getAppConfig": return try .encoding(await client.getAppConfig())
    case "updateEmail":
      return try .encoding(
        await client.updateEmail(
          input: .init(email: "new@example.invalid", password: "synthetic-old")))
    case "updatePassword":
      return try .encoding(
        await client.updatePassword(
          input: .init(currentPassword: "synthetic-old", newPassword: "synthetic-new")))
    case "setPassword":
      return try .encoding(await client.setPassword(input: .init(newPassword: "synthetic-new")))
    case "deleteAccount":
      return try .encoding(
        await client.deleteAccount(input: .init(password: "synthetic-old", confirmDeletion: true)))
    case "validateToken": return try .encoding(await client.validateToken())
    case "unlinkSocialAccount": return try .encoding(await client.unlinkSocialAccount(id: id))
    case "beginPasskeyRegistration": return try await client.beginPasskeyRegistration()
    case "finishPasskeyRegistration":
      return try .encoding(
        await client.finishPasskeyRegistration(name: "Synthetic key", credential: Self.credential))
    case "beginPasskey2FA": return try await client.beginPasskey2FA(tempToken: "synthetic-temp")
    case "beginPasskeyEnrollment": return try await client.beginPasskeyEnrollment()
    case "finishPasskeyEnrollment":
      return try .encoding(await client.finishPasskeyEnrollment(credential: Self.credential))
    case "beginPasswordlessLogin": return try .encoding(await client.beginPasswordlessLogin())
    case "listPasskeys": return try .encoding(await client.listPasskeys())
    case "renamePasskey":
      return try .encoding(await client.renamePasskey(id: id, name: "Synthetic key"))
    case "deletePasskey": return try .encoding(await client.deletePasskey(id: id))
    case "revokeSession": return try .encoding(await client.revokeSession(id: id))
    case "revokeOtherSessions": return try .encoding(await client.revokeOtherSessions())
    default:
      let result = try await login(name, client: client)
      guard case .authenticated(let tokens) = result else {
        throw MMGTError.invalidResponse("Expected complete synthetic login")
      }
      return [
        "access_token": .string(tokens.accessToken), "refresh_token": .string(tokens.refreshToken),
      ]
    }
  }
  func login(_ name: String, client: AuthClient) async throws -> LoginResult {
    switch name {
    case "confirmMerge":
      return try await client.confirmMerge(
        input: .init(mergeToken: "synthetic-merge", password: "synthetic-old"))
    case "verify2FALogin":
      return try await client.verify2FALogin(
        input: .init(
          tempToken: "synthetic-temp", recoveryCode: "synthetic-recovery", rememberDevice: false))
    case "finishPasskey2FA":
      return try await client.finishPasskey2FA(
        tempToken: "synthetic-temp", credential: Self.credential)
    case "finishPasswordlessLogin":
      return try await client.finishPasswordlessLogin(
        sessionID: "synthetic-session", credential: Self.credential)
    default: throw MMGTError.unsupported(name)
    }
  }

  @Test(arguments: endpoints)
  func accountAndPasskeyWireContract(_ endpoint: Endpoint) async throws {
    let data =
      try endpoint.fixture.map { try SharedWireContractTests().data($0) }
      ?? Data(#"{"message":"Synthetic completion"}"#.utf8)
    let wire = try JSONDecoder().decode(JSONValue.self, from: data)
    let transport = RecordingTransport([.init(data: data, status: 200)])
    let result = try await call(endpoint.name, client: AuthMFAContractTests().client(transport))
    if endpoint.login {
      #expect(result == ["access_token": "synthetic-access", "refresh_token": "synthetic-refresh"])
    } else {
      #expect(result == (endpoint.options ? wire["options"]! : wire))
    }
    let request = try #require(await transport.requests.first)
    #expect(await transport.requests.count == 1)
    #expect(request.httpMethod == endpoint.method && request.url?.path == "/auth/" + endpoint.path)
    #expect(request.url?.query == nil)
    #expect(request.value(forHTTPHeaderField: "X-App-ID") == "11111111-1111-4111-8111-111111111111")
    #expect(
      request.value(forHTTPHeaderField: "Authorization")
        == (endpoint.authenticated ? "Bearer synthetic-access" : nil))
    #expect(
      try request.httpBody.map { try JSONDecoder().decode(JSONValue.self, from: $0) }
        == endpoint.body)
  }

  @Test(arguments: endpoints.filter(\.authenticated))
  func managementRequiresTokenBeforeNetwork(_ endpoint: Endpoint) async throws {
    let transport = RecordingTransport([])
    await #expect(throws: MMGTError.unauthenticated) {
      _ = try await call(
        endpoint.name, client: AuthMFAContractTests().client(transport, token: nil))
    }
    #expect(await transport.requests.isEmpty)
  }

  @Test(arguments: endpoints.filter(\.login), ["auth-enrollment", "auth-passwordexpired"])
  func passkeyAndSecondaryCredentialsPreserveRestrictedLogin(
    _ endpoint: Endpoint, _ fixture: String
  ) async throws {
    let transport = RecordingTransport([
      .init(data: try SharedWireContractTests().data(fixture), status: 200)
    ])
    let result = try await login(endpoint.name, client: AuthMFAContractTests().client(transport))
    if fixture == "auth-enrollment" {
      guard case .requiresTwoFactorSetup = result else {
        Issue.record("Enrollment became a service session")
        return
      }
    } else {
      #expect(result == .passwordExpired)
    }
    #expect(await transport.requests.count == 1)
  }

  @Test(arguments: [400, 401, 403, 409, 429, 503])
  func failedAccountMutationsAreNotRetried(_ status: Int) async throws {
    for endpoint in Self.endpoints where endpoint.method != "GET" {
      let transport = RecordingTransport([
        .init(
          data: Data(#"{"error":"Synthetic rejection"}"#.utf8), status: status,
          headers: ["X-Request-ID": "synthetic-request"])
      ])
      do {
        _ = try await call(endpoint.name, client: AuthMFAContractTests().client(transport))
        Issue.record("Expected explicit rejection")
      } catch let error as APIError {
        #expect(error.status == status && error.requestID == "synthetic-request")
      }
      #expect(await transport.requests.count == 1)
    }
  }

  @Test func deletionRequiresExplicitConfirmationAndPreservesSocialOnlyBody() async throws {
    let transport = RecordingTransport([
      .init(data: Data(#"{"message":"Synthetic completion"}"#.utf8), status: 200)
    ])
    let client = try AuthMFAContractTests().client(transport)
    await #expect(throws: MMGTError.self) {
      _ = try await client.deleteAccount(input: .init(confirmDeletion: false))
    }
    #expect(await transport.requests.isEmpty)
    _ = try await client.deleteAccount(input: .init(confirmDeletion: true))
    let request = try #require(await transport.requests.first)
    #expect(
      try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody)) == [
        "confirm_deletion": true
      ])
  }
}
