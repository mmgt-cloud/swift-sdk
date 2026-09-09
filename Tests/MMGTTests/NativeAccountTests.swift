import CryptoKit
import Foundation
import MMGTCore
import Testing
import UIKit

@testable import MMGTAuth

@Suite(.timeLimit(.minutes(1))) struct NativeAccountTests {
  @Test func pkceAndStateAreIndependentAndCallbackIsExact() throws {
    let proof = try NativeAccountProof()
    let another = try NativeAccountProof()
    #expect(proof.state.count == 43 && proof.verifier.count == 43)
    #expect(proof.state != proof.verifier && proof.verifier != another.verifier)
    #expect(proof.challenge == Base64URL.encode(Data(SHA256.hash(data: Data(proof.verifier.utf8)))))
    let registered = URL(string: "https://example.invalid/native/callback")!
    let id = UUID().uuidString
    let valid = "\(registered)?code=\(id)&state=\(proof.state)"
    #expect(try proof.code(from: URL(string: valid)!, registered: registered) == id)
    for value in [
      valid + "&state=\(proof.state)", valid + "#ignored",
      valid.replacingOccurrences(of: "example.invalid", with: "foreign.invalid"),
      valid.replacingOccurrences(of: proof.state, with: another.state),
      valid.replacingOccurrences(of: "/callback?", with: "/other?"),
      valid.replacingOccurrences(of: "code=\(id)", with: "code=not-a-code"),
    ] {
      #expect(throws: MMGTError.self) {
        try proof.code(from: URL(string: value)!, registered: registered)
      }
    }
  }
  @Test func nativeAccountExchangeKeepsSecretsInBodiesAndHeaders() async throws {
    let transport = RecordingTransport([
      .init(
        data: Data(
          #"{"url":"https://provider.example.invalid/authorize?state=synthetic","expires_in":300}"#
            .utf8), status: 200),
      .init(data: Data(#"{"linked":true,"provider":"apple"}"#.utf8), status: 200),
    ])
    let configuration = try ServiceConfiguration(
      baseURL: URL(string: "https://api.example.invalid/auth")!, appID: "app-a")
    let native = try NativeOIDCConfiguration(
      auth: configuration, clientID: "native-a",
      redirectURL: URL(string: "https://example.invalid/native/callback")!)
    let client = AuthClient(
      configuration: configuration, tokenProvider: { "synthetic-access" }, transport: transport)
    let proof = try NativeAccountProof()
    _ = try await client.startNativeAccount(
      configuration: native, provider: .apple, action: "link", proof: proof)
    let result = try await client.finishNativeAccount(
      code: UUID().uuidString, proof: proof, as: LinkedProvider.self)
    #expect(result.linked && result.provider == .apple)
    let requests = await transport.requests
    #expect(
      requests.map { $0.url?.path } == [
        "/auth/profile/native-provider/start", "/auth/profile/native-provider/finish",
      ])
    #expect(
      requests.allSatisfy {
        $0.url?.query == nil
          && $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access"
      })
    let start = try JSONDecoder().decode(JSONValue.self, from: requests[0].httpBody!)
    let finish = try JSONDecoder().decode(JSONValue.self, from: requests[1].httpBody!)
    #expect(start["code_challenge"] == .string(proof.challenge) && start["code_verifier"] == nil)
    #expect(finish["code_verifier"] == .string(proof.verifier))
  }
  @Test func accountOperationCannotReturnLateResultAfterLogout() async throws {
    let (session, store, transport) = try SessionTests().fixture()
    let login = Task {
      try await session.authenticate { _ in
        .authenticated(.init(accessToken: "synthetic-access", refreshToken: "synthetic-refresh"))
      }
    }
    await transport.waitForRequest(0)
    await transport.reply(0, profile)
    _ = try await login.value
    let work = Task { try await session.performAccountOperation { try await $0.getProfile() } }
    await transport.waitForRequest(1)
    try await session.signOutLocally()
    await transport.reply(1, profile)
    do {
      _ = try await work.value
      Issue.record("Late account operation returned success")
    } catch { #expect(error is CancellationError || error as? MMGTError == .sessionChanged) }
    #expect(store.load() == nil)
    #expect(await session.identity == nil)
  }
  @MainActor @Test func cancellingDuringStartDoesNotLaunchTheBrowserOrFinish() async throws {
    let (session, _, transport) = try SessionTests().fixture()
    let login = Task {
      try await session.authenticate { _ in
        .authenticated(.init(accessToken: "synthetic-access", refreshToken: "synthetic-refresh"))
      }
    }
    await transport.waitForRequest(0)
    await transport.reply(0, profile)
    _ = try await login.value
    let native = try NativeOIDCConfiguration(
      auth: session.configuration, clientID: "native-a",
      redirectURL: URL(string: "https://example.invalid/native/callback")!)
    let authorizer = NativeAccountAuthorizer()
    let task = Task {
      try await authorizer.link(
        provider: .apple, configuration: native, session: session, presentationAnchor: UIWindow())
    }
    await transport.waitForRequest(1)
    authorizer.cancel()
    await transport.reply(1, #"{"url":"https://provider.example.invalid/authorize"}"#)
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await transport.requests.count == 2)
  }
  private var profile: String {
    #"{"id":"user-a","email":"synthetic@example.invalid","email_verified":true,"two_fa_enabled":false,"has_password":true,"created_at":"2026-09-09T12:00:00Z","updated_at":"2026-09-09T12:00:00Z"}"#
  }
}
