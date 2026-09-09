import Foundation
import MMGTCore
import Testing

@testable import MMGTAuth

@Suite struct NativeAuthTests {
  @Test func webAuthnSerializationUsesExactBase64URLBytes() throws {
    let id = Data([255, 0, 127, 254])
    let clientData = Data(
      #"{"type":"webauthn.get","challenge":"test","origin":"https://example.invalid"}"#.utf8)
    #expect(try Base64URL.decode(Base64URL.encode(id)) == id)
    #expect(!Base64URL.encode(id).contains("="))
    #expect(throws: MMGTError.self) { try Base64URL.decode("a") }
    #expect(throws: MMGTError.self) { try Base64URL.decode("YWJj\n") }
    let wire = NativePasskeys.assertionJSON(
      id: id, clientData: clientData, authenticatorData: id, signature: id, userID: Data())
    #expect(wire["id"] == wire["rawId"])
    #expect(wire["response"]?["userHandle"] == .null)
    #expect(try Base64URL.decode(wire["response"]!["clientDataJSON"]!.string!) == clientData)
  }
  @Test func nativeCallbackRequiresExplicitDevelopmentOptIn() throws {
    let auth = try ServiceConfiguration(
      baseURL: URL(string: "https://api.example.invalid/auth")!, appID: "app-a")
    _ = try NativeOIDCConfiguration(
      auth: auth, clientID: "client-a",
      redirectURL: URL(string: "https://example.invalid/oauth/callback")!)
    #expect(throws: MMGTError.self) {
      try NativeOIDCConfiguration(
        auth: auth, clientID: "client-a", redirectURL: URL(string: "com.example.app:/callback")!)
    }
    _ = try NativeOIDCConfiguration(
      auth: auth, clientID: "client-a", redirectURL: URL(string: "com.example.app:/callback")!,
      allowCustomSchemeForDevelopment: true)
    #expect(throws: MMGTError.self) {
      try NativeOIDCConfiguration(
        auth: auth, clientID: "client-a",
        redirectURL: URL(string: "http://example.invalid/callback")!,
        allowCustomSchemeForDevelopment: true)
    }
  }
  @Test func discoveryKeepsLegacyIssuerButRejectsForeignAppOrHost() throws {
    let auth = try ServiceConfiguration(
      baseURL: URL(string: "https://api.example.invalid/auth")!, appID: "app-a")
    let metadata: JSONValue = [
      "issuer": "https://api.example.invalid/oidc/app-a",
      "authorization_endpoint": "https://api.example.invalid/auth/oidc/app-a/authorize",
      "token_endpoint": "https://api.example.invalid/auth/oidc/app-a/token",
    ]
    let endpoints = try OIDCAuthorizer.validateDiscovery(metadata, configuration: auth)
    #expect(endpoints.issuer.absoluteString == "https://api.example.invalid/oidc/app-a")
    for bad in [
      "https://attacker.example.invalid/oidc/app-a/token",
      "https://api.example.invalid/oidc/app-b/token",
      "https://api.example.invalid/foreign/oidc/app-a/token",
      "https://api.example.invalid/oidc/app-a/token",
    ] {
      var fields: [String: JSONValue] = [
        "issuer": metadata["issuer"]!,
        "authorization_endpoint": metadata["authorization_endpoint"]!,
        "token_endpoint": .string(bad),
      ]
      #expect(throws: MMGTError.self) {
        try OIDCAuthorizer.validateDiscovery(.object(fields), configuration: auth)
      }
      fields.removeAll()
    }
  }
  @Test func openIDLoginRequiresIDTokenAndRejectsAnErroredExchange() throws {
    for absent in [nil, ""] as [String?] {
      #expect(throws: MMGTError.self) {
        try OIDCAuthorizer.loginResult(
          access: "synthetic-access", refresh: "synthetic-refresh", idToken: absent,
          error: nil
        ).get()
      }
    }
    #expect(throws: CancellationError.self) {
      try OIDCAuthorizer.loginResult(
        access: "synthetic-access", refresh: "synthetic-refresh", idToken: "synthetic-id",
        error: CancellationError()
      ).get()
    }
    let result = try OIDCAuthorizer.loginResult(
      access: "synthetic-access", refresh: "synthetic-refresh", idToken: "synthetic-id",
      error: nil
    ).get()
    guard case .authenticated(let tokens) = result else {
      Issue.record("Validated OpenID exchange did not produce a session")
      return
    }
    #expect(tokens.accessToken == "synthetic-access")
  }
}
