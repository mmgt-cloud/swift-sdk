@preconcurrency import AppAuth
import CryptoKit
import Foundation
import MMGTCore
import Testing
import UIKit

@testable import MMGTAuth

@MainActor @Suite(.timeLimit(.minutes(1))) struct NativeOIDCRequestTests {
  func configuration() throws -> NativeOIDCConfiguration {
    try .init(
      auth: .init(
        baseURL: URL(string: "https://api.example.invalid/auth")!, appID: "synthetic-app"),
      clientID: "synthetic-public-client",
      redirectURL: URL(string: "https://login.example.invalid/native/callback")!)
  }
  var metadata: JSONValue {
    [
      "issuer": "https://api.example.invalid/oidc/synthetic-app",
      "authorization_endpoint": "https://api.example.invalid/oidc/synthetic-app/authorize",
      "token_endpoint": "https://api.example.invalid/oidc/synthetic-app/token",
    ]
  }
  @Test func appAuthRequestHasPKCEIndependentStateNonceAndNoClientSecret() throws {
    let config = try configuration()
    let first = try OIDCAuthorizer.authorizationRequest(
      metadata: metadata, configuration: config, forceLogin: true)
    let second = try OIDCAuthorizer.authorizationRequest(
      metadata: metadata, configuration: config, forceLogin: false)
    let verifier = try #require(first.codeVerifier)
    #expect(verifier.count >= 43 && verifier.count <= 128)
    #expect(first.codeChallengeMethod == "S256")
    #expect(first.codeChallenge == Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8)))))
    #expect(first.clientSecret == nil && second.clientSecret == nil)
    let values = [
      try #require(first.state), try #require(first.nonce), verifier,
      try #require(second.state), try #require(second.nonce), try #require(second.codeVerifier),
    ]
    #expect(values.allSatisfy { $0.count >= 32 } && Set(values).count == values.count)
    let url = first.authorizationRequestURL()
    let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    let parameters = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
    #expect(
      parameters == [
        "client_id": config.clientID, "response_type": "code",
        "redirect_uri": config.redirectURL.absoluteString,
        "scope": "openid profile email offline_access", "state": first.state!,
        "nonce": first.nonce!,
        "code_challenge": first.codeChallenge!, "code_challenge_method": "S256", "prompt": "login",
      ])
    #expect(second.additionalParameters?["prompt"] == nil)
  }

  @Test func cancelledDiscoveryCannotPresentOrCreateAnotherRequest() async throws {
    let transport = ControlledTransport()
    let authorizer = OIDCAuthorizer(transport: transport)
    let task = Task {
      try await authorizer.signIn(
        configuration: configuration(), presentationAnchor: UIWindow(frame: .zero))
    }
    await transport.waitForRequest(0)
    task.cancel()
    await transport.reply(0, String(data: try JSONEncoder().encode(metadata), encoding: .utf8)!)
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(await transport.requests.count == 1)
    #expect(
      await transport.requests[0].url?.path
        == "/auth/oidc/synthetic-app/.well-known/openid-configuration")
    #expect(
      try authorizer.resume(
        URL(string: "https://login.example.invalid/native/callback?code=synthetic")!) == false)
  }
}
