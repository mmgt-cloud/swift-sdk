import AuthenticationServices
import CryptoKit
import Foundation
import MMGTCore
import Security
import UIKit

public enum NativeAccountProvider: String, Codable, Sendable {
  case google, facebook, github, apple
}
public struct LinkedProvider: Codable, Sendable, Equatable {
  public let linked: Bool
  public let provider: NativeAccountProvider
}

struct NativeAccountProof: Sendable {
  let state: String
  let verifier: String
  var challenge: String { Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8)))) }
  init() throws {
    func random() throws -> String {
      var bytes = [UInt8](repeating: 0, count: 32)
      guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw MMGTError.invalidConfiguration("Secure random source unavailable")
      }
      return Base64URL.encode(Data(bytes))
    }
    state = try random()
    verifier = try random()
  }
  func code(from callback: URL, registered: URL) throws -> String {
    guard callback.scheme == registered.scheme, callback.host == registered.host,
      callback.port == registered.port, callback.path == registered.path,
      callback.user == nil, callback.password == nil, callback.fragment == nil,
      let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
      query.count == 2, query.filter({ $0.name == "state" }).count == 1,
      query.first(where: { $0.name == "state" })?.value == state,
      let code = query.first(where: { $0.name == "code" })?.value, UUID(uuidString: code) != nil
    else { throw MMGTError.invalidResponse("Native account callback or state mismatch") }
    return code
  }
}

extension AuthClient {
  func startNativeAccount(
    configuration: NativeOIDCConfiguration, provider: NativeAccountProvider,
    action: String, proof: NativeAccountProof
  ) async throws -> URL {
    guard self.configuration == configuration.auth else { throw MMGTError.sessionChanged }
    let response: JSONValue = try await http.request(
      path: ["profile", "native-provider", "start"], method: "POST",
      body: [
        "client_id": .string(configuration.clientID),
        "redirect_uri": .string(configuration.redirectURL.absoluteString),
        "provider": .string(provider.rawValue), "action": .string(action),
        "state": .string(proof.state),
        "code_challenge": .string(proof.challenge),
      ])
    guard let value = response["url"]?.string, let url = URL(string: value), url.scheme == "https",
      url.host != nil, url.user == nil, url.password == nil, url.fragment == nil
    else { throw MMGTError.invalidResponse("Invalid provider authorization URL") }
    return url
  }
  func finishNativeAccount<T: Decodable & Sendable>(
    code: String, proof: NativeAccountProof, as type: T.Type
  ) async throws -> T {
    try await http.request(
      type, path: ["profile", "native-provider", "finish"], method: "POST",
      body: [
        "code": .string(code), "code_verifier": .string(proof.verifier),
      ])
  }
}

/// System-browser account linking and provider reauthentication. AuthSession owns cancellation.
/// Provider tokens never enter the app; the callback carries only state and a PKCE-bound opaque code.
@MainActor
public final class NativeAccountAuthorizer: NSObject,
  ASWebAuthenticationPresentationContextProviding
{
  private var browser: ASWebAuthenticationSession?
  private var anchor: UIWindow?
  private var continuation: CheckedContinuation<URL, any Error>?
  private var activeOperation: UUID?
  public override init() { super.init() }

  public func link(
    provider: NativeAccountProvider, configuration: NativeOIDCConfiguration,
    session: AuthSession, presentationAnchor: UIWindow
  ) async throws -> LinkedProvider {
    let result: LinkedProvider = try await run(
      provider: provider, action: "link", configuration: configuration,
      session: session, presentationAnchor: presentationAnchor)
    guard result.linked, result.provider == provider else {
      throw MMGTError.invalidResponse("Provider link was not confirmed")
    }
    return result
  }
  /// The platform currently supports provider reauthentication with Google and Apple.
  public func reauthenticate(
    provider: NativeAccountProvider, configuration: NativeOIDCConfiguration,
    session: AuthSession, presentationAnchor: UIWindow
  ) async throws -> ReauthenticationProof {
    guard provider == .google || provider == .apple else {
      throw MMGTError.unsupported("Use password, passkey, Google or Apple reauthentication")
    }
    return try await run(
      provider: provider, action: "reauth", configuration: configuration,
      session: session, presentationAnchor: presentationAnchor)
  }
  private func run<T: Decodable & Sendable>(
    provider: NativeAccountProvider, action: String,
    configuration: NativeOIDCConfiguration, session: AuthSession, presentationAnchor: UIWindow
  ) async throws -> T {
    guard activeOperation == nil else {
      throw MMGTError.invalidConfiguration("An account browser operation is already in progress")
    }
    guard session.configuration == configuration.auth else { throw MMGTError.sessionChanged }
    let operation = UUID()
    activeOperation = operation
    defer {
      if activeOperation == operation {
        activeOperation = nil
        anchor = nil
      }
    }
    let proof = try NativeAccountProof()
    let result: T = try await session.performAccountOperation { client in
      let url = try await client.startNativeAccount(
        configuration: configuration, provider: provider, action: action, proof: proof)
      try Task.checkCancellation()
      let callback = try await self.present(
        url: url, redirect: configuration.redirectURL, anchor: presentationAnchor,
        operation: operation)
      try Task.checkCancellation()
      let code = try proof.code(from: callback, registered: configuration.redirectURL)
      return try await client.finishNativeAccount(code: code, proof: proof, as: T.self)
    }
    guard activeOperation == operation else { throw CancellationError() }
    return result
  }
  private func present(url: URL, redirect: URL, anchor: UIWindow, operation: UUID) async throws
    -> URL
  {
    guard operation == activeOperation else { throw CancellationError() }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        self.continuation = continuation
        self.anchor = anchor
        let callback: ASWebAuthenticationSession.Callback =
          redirect.scheme == "https"
          ? .https(host: redirect.host!, path: redirect.path) : .customScheme(redirect.scheme!)
        let browser = ASWebAuthenticationSession(url: url, callback: callback) {
          [weak self] url, error in
          Task { @MainActor in
            guard let self, self.activeOperation == operation else { return }
            if let url {
              self.complete(.success(url))
            } else {
              self.complete(
                .failure(
                  error.map { OIDCAuthorizer.isCancellation($0) ? CancellationError() : $0 }
                    ?? CancellationError()))
            }
          }
        }
        browser.presentationContextProvider = self
        browser.prefersEphemeralWebBrowserSession = true
        self.browser = browser
        if !browser.start() {
          complete(.failure(MMGTError.invalidConfiguration("System browser could not start")))
        }
      }
    } onCancel: {
      Task { @MainActor in if self.activeOperation == operation { self.cancel() } }
    }
  }
  private func complete(_ result: Result<URL, any Error>) {
    let continuation = continuation
    self.continuation = nil
    browser = nil
    continuation?.resume(with: result)
  }
  public func cancel() {
    activeOperation = nil
    let browser = browser
    complete(.failure(CancellationError()))
    anchor = nil
    browser?.cancel()
  }
  public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    anchor ?? UIWindow()
  }
}
