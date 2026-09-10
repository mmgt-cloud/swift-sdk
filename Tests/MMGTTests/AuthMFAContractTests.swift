import Foundation
import MMGTAuth
import MMGTCore
import Testing

@Suite struct AuthMFAContractTests {
  struct Endpoint: Sendable {
    let name, method, path: String
    var authenticated = true
    var body: JSONValue? = nil
    var fixture: String? = nil
  }
  static let endpoints: [Endpoint] = [
    .init(name: "generate2FA", method: "POST", path: "2fa/generate", fixture: "auth-totp"),
    .init(
      name: "verify2FASetup", method: "POST", path: "2fa/verify-setup", body: ["code": "012345"]),
    .init(name: "enable2FA", method: "POST", path: "2fa/enable", fixture: "auth-enabled"),
    .init(name: "disable2FA", method: "POST", path: "2fa/disable", body: ["code": "012345"]),
    .init(
      name: "generateRecoveryCodes", method: "POST", path: "2fa/recovery-codes",
      body: ["code": "012345"], fixture: "auth-enabled"),
    .init(
      name: "enableEmail2FA", method: "POST", path: "2fa/email/enable", fixture: "auth-enabled"),
    .init(name: "enableSMS2FA", method: "POST", path: "2fa/sms/enable", fixture: "auth-enabled"),
    .init(
      name: "enableBackupEmail2FA", method: "POST", path: "2fa/backup-email/enable",
      fixture: "auth-enabled"),
    .init(
      name: "disableBackupEmail2FA", method: "POST", path: "2fa/backup-email/disable",
      body: ["code": "012345"]),
    .init(
      name: "resendEmail2FACode", method: "POST", path: "2fa/email/resend", authenticated: false,
      body: ["temp_token": "synthetic-temp"]),
    .init(
      name: "resendSMS2FACode", method: "POST", path: "2fa/sms/resend", authenticated: false,
      body: ["temp_token": "synthetic-temp"]),
    .init(
      name: "resendBackupEmail2FACode", method: "POST", path: "2fa/backup-email/resend",
      authenticated: false, body: ["temp_token": "synthetic-temp"]),
    .init(
      name: "get2FAMethods", method: "GET", path: "2fa/methods", authenticated: false,
      fixture: "auth-methods"),
    .init(
      name: "addBackupEmail", method: "POST", path: "2fa/backup-email",
      body: ["backup_email": "backup@example.invalid"]),
    .init(name: "removeBackupEmail", method: "DELETE", path: "2fa/backup-email"),
    .init(
      name: "getBackupEmailStatus", method: "GET", path: "2fa/backup-email/status",
      fixture: "auth-backup"),
    .init(
      name: "verifyBackupEmail", method: "GET", path: "2fa/backup-email/verify",
      authenticated: false),
    .init(name: "addPhone", method: "POST", path: "phone", body: ["phone_number": "+12025550123"]),
    .init(name: "verifyPhone", method: "POST", path: "phone/verify", body: ["code": "012345"]),
    .init(name: "removePhone", method: "DELETE", path: "phone"),
    .init(name: "getPhoneStatus", method: "GET", path: "phone/status", fixture: "auth-phone"),
    .init(
      name: "listTrustedDevices", method: "GET", path: "2fa/trusted-devices",
      fixture: "auth-trusted"),
    .init(
      name: "revokeTrustedDevice", method: "DELETE",
      path: "2fa/trusted-devices/33333333-3333-4333-8333-333333333333"),
    .init(name: "revokeAllTrustedDevices", method: "DELETE", path: "2fa/trusted-devices"),
  ]
  func call(_ name: String, client: AuthClient) async throws -> JSONValue {
    switch name {
    case "generate2FA": return try .encoding(await client.generate2FA())
    case "verify2FASetup": return try .encoding(await client.verify2FASetup(code: "012345"))
    case "enable2FA": return try .encoding(await client.enable2FA())
    case "disable2FA": return try .encoding(await client.disable2FA(code: "012345"))
    case "generateRecoveryCodes":
      return try .encoding(await client.generateRecoveryCodes(code: "012345"))
    case "enableEmail2FA": return try .encoding(await client.enableEmail2FA())
    case "enableSMS2FA": return try .encoding(await client.enableSMS2FA())
    case "enableBackupEmail2FA": return try .encoding(await client.enableBackupEmail2FA())
    case "disableBackupEmail2FA":
      return try .encoding(await client.disableBackupEmail2FA(code: "012345"))
    case "resendEmail2FACode":
      return try .encoding(await client.resendEmail2FACode(tempToken: "synthetic-temp"))
    case "resendSMS2FACode":
      return try .encoding(await client.resendSMS2FACode(tempToken: "synthetic-temp"))
    case "resendBackupEmail2FACode":
      return try .encoding(await client.resendBackupEmail2FACode(tempToken: "synthetic-temp"))
    case "get2FAMethods": return try .encoding(await client.get2FAMethods())
    case "addBackupEmail":
      return try .encoding(
        await client.addBackupEmail(input: .init(backupEmail: "backup@example.invalid")))
    case "removeBackupEmail": return try .encoding(await client.removeBackupEmail())
    case "getBackupEmailStatus": return try .encoding(await client.getBackupEmailStatus())
    case "verifyBackupEmail":
      return try .encoding(await client.verifyBackupEmail(token: "synthetic+/=?#"))
    case "addPhone":
      return try .encoding(await client.addPhone(input: .init(phoneNumber: "+12025550123")))
    case "verifyPhone": return try .encoding(await client.verifyPhone(input: .init(code: "012345")))
    case "removePhone": return try .encoding(await client.removePhone())
    case "getPhoneStatus": return try .encoding(await client.getPhoneStatus())
    case "listTrustedDevices": return try .encoding(await client.listTrustedDevices())
    case "revokeTrustedDevice":
      return try .encoding(
        await client.revokeTrustedDevice(id: "33333333-3333-4333-8333-333333333333"))
    case "revokeAllTrustedDevices": return try .encoding(await client.revokeAllTrustedDevices())
    default: throw MMGTError.unsupported(name)
    }
  }
  func client(_ transport: RecordingTransport, token: String? = "synthetic-access") throws
    -> AuthClient
  {
    .init(
      configuration: try .init(
        baseURL: URL(string: "https://api.example.invalid/auth")!,
        appID: "11111111-1111-4111-8111-111111111111"), tokenProvider: { token ?? "" },
      transport: transport)
  }
  @Test(arguments: endpoints)
  func securityEndpointsMatchServerBodiesAuthenticationAndDTOs(_ endpoint: Endpoint) async throws {
    let fixture = SharedWireContractTests()
    let data =
      try endpoint.fixture.map { try fixture.data($0) }
      ?? Data(#"{"message":"Synthetic completion"}"#.utf8)
    let transport = RecordingTransport([.init(data: data, status: 200)])
    let result = try await call(endpoint.name, client: client(transport))
    #expect(result == (try JSONDecoder().decode(JSONValue.self, from: data)))
    let request = try #require(await transport.requests.first)
    #expect(await transport.requests.count == 1)
    #expect(request.httpMethod == endpoint.method && request.url?.path == "/auth/" + endpoint.path)
    #expect(request.value(forHTTPHeaderField: "X-App-ID") == "11111111-1111-4111-8111-111111111111")
    #expect(
      request.value(forHTTPHeaderField: "Authorization")
        == (endpoint.authenticated ? "Bearer synthetic-access" : nil))
    #expect(
      try request.httpBody.map { try JSONDecoder().decode(JSONValue.self, from: $0) }
        == endpoint.body)
    if endpoint.name == "verifyBackupEmail" {
      #expect(
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems == [
          .init(name: "token", value: "synthetic+/=?#")
        ])
    } else {
      #expect(request.url?.query == nil)
    }
  }
  @Test(arguments: endpoints.filter(\.authenticated))
  func protectedSecurityOperationsRequireUserTokenBeforeNetwork(_ endpoint: Endpoint) async throws {
    let transport = RecordingTransport([])
    await #expect(throws: MMGTError.unauthenticated) {
      _ = try await call(endpoint.name, client: client(transport, token: nil))
    }
    #expect(await transport.requests.isEmpty)
  }
  @Test(arguments: [400, 401, 403, 429, 503])
  func uncertainSecurityMutationsAreNeverAutomaticallyRetried(_ status: Int) async throws {
    let transport = RecordingTransport([
      .init(
        data: Data(#"{"error":"Synthetic MFA policy or verification failure"}"#.utf8),
        status: status, headers: ["X-Request-ID": "synthetic-request"])
    ])
    do {
      _ = try await client(transport).generateRecoveryCodes(code: "012345")
      Issue.record("Expected failure")
    } catch let error as APIError {
      #expect(error.status == status && error.requestID == "synthetic-request")
    }
    #expect(await transport.requests.count == 1)
  }
}
