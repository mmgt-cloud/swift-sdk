import Foundation
import MMGTAuth
import MMGTCore
import Testing

@Suite struct AuthContractTests {
  @Test func emailCredentialsPreserveMFAAndReauthenticationProof() async throws {
    let transport = RecordingTransport([
      .init(
        data: Data(#"{"requires_2fa":true,"temp_token":"synthetic-temp","method":"totp"}"#.utf8),
        status: 202, headers: [:]),
      .init(
        data: Data(
          #"{"access_token":"synthetic-enrollment","refresh_token":"synthetic-refresh","message":"2FA setup is required"}"#
            .utf8), status: 202, headers: [:]),
      .init(
        data: Data(#"{"reauth_token":"synthetic-proof","expires_in":300}"#.utf8), status: 200,
        headers: [:]),
      .init(data: Data(#"{"message":"Check the new address"}"#.utf8), status: 200, headers: [:]),
    ])
    let configuration = try ServiceConfiguration(
      baseURL: URL(string: "https://api.example.invalid/auth")!, appID: "synthetic-app")
    let client = AuthClient(
      configuration: configuration, tokenProvider: { "synthetic-access" }, transport: transport)
    let login = try await client.verifyLoginCode(email: "synthetic@example.invalid", code: "123456")
    guard case .requiresTwoFactor(let temporary, _, _) = login else {
      Issue.record("MFA was lost")
      return
    }
    #expect(temporary == "synthetic-temp")
    #expect(!String(describing: login).contains(temporary))
    guard
      case .requiresTwoFactorSetup = try await client.verifyRegistrationCode(
        email: "synthetic@example.invalid", code: "123456")
    else {
      Issue.record("Enrollment was lost")
      return
    }
    let proof = try await client.reauthenticateWithPassword(currentPassword: "synthetic-password")
    #expect(proof.expiresIn == 300)
    #expect(!String(describing: proof).contains(proof.token))
    _ = try await client.startEmailChange(newEmail: "changed@example.invalid", proof: proof)
    let requests = await transport.requests
    #expect(
      requests.map { $0.url?.path } == [
        "/auth/login/otp/verify", "/auth/register/otp/verify", "/auth/profile/reauth/password",
        "/auth/profile/email/change/start",
      ])
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
    let body = try JSONDecoder().decode(JSONValue.self, from: requests[3].httpBody!)
    #expect(body["reauth_token"] == .string("synthetic-proof"))
  }
  @Test func mfaAndMergeUseRegisteredServerRoutes() async throws {
    let response = HTTPResponse(
      data: Data(#"{"access_token":"synthetic-access","refresh_token":"synthetic-refresh"}"#.utf8),
      status: 200, headers: [:])
    let transport = RecordingTransport([response, response])
    let configuration = try ServiceConfiguration(
      baseURL: URL(string: "https://api.example.invalid/auth")!, appID: "synthetic-app")
    let client = AuthClient(configuration: configuration, transport: transport)
    _ = try await client.verify2FALogin(input: .init(tempToken: "synthetic-temp", code: "123456"))
    _ = try await client.confirmMerge(
      input: .init(mergeToken: "synthetic-merge", password: "synthetic-password"))
    let requests = await transport.requests
    #expect(requests.map { $0.url?.path } == ["/auth/2fa/login-verify", "/auth/merge/confirm"])
    #expect(
      requests.allSatisfy {
        $0.httpMethod == "POST" && $0.value(forHTTPHeaderField: "Authorization") == nil
      })
    let body = try JSONDecoder().decode(JSONValue.self, from: requests[0].httpBody!)
    #expect(body["temp_token"] == .string("synthetic-temp"))
    #expect(body["code"] == .string("123456"))
  }
}
