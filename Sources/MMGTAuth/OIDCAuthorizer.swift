@preconcurrency import AppAuth
import AuthenticationServices
import Foundation
import MMGTCore
import UIKit

public struct NativeOIDCConfiguration: Sendable {
  public let auth: ServiceConfiguration
  public let clientID: String
  public let redirectURL: URL
  public init(
    auth: ServiceConfiguration, clientID: String, redirectURL: URL,
    allowCustomSchemeForDevelopment: Bool = false
  ) throws {
    let https =
      redirectURL.scheme == "https" && redirectURL.host != nil && !redirectURL.path.isEmpty
    let custom =
      allowCustomSchemeForDevelopment && redirectURL.scheme?.contains(".") == true
      && redirectURL.scheme != "https" && redirectURL.scheme != "http"
    guard !clientID.isEmpty, https || custom, redirectURL.user == nil, redirectURL.password == nil,
      redirectURL.query == nil, redirectURL.fragment == nil, redirectURL.port == nil
    else {
      throw MMGTError.invalidConfiguration(
        "Register an exact HTTPS callback, or explicitly allow a reverse-domain development scheme")
    }
    self.auth = auth
    self.clientID = clientID
    self.redirectURL = redirectURL
  }
}

/// Uses AppAuth for OAuth/OIDC validation and code exchange; AuthSession owns subsequent refresh.
@MainActor public final class OIDCAuthorizer {
  private var flow: (any OIDExternalUserAgentSession)?
  private var agent: SystemBrowserAgent?
  private var pending: CheckedContinuation<LoginResult, any Error>?
  private var generation = UUID()
  private let transport: any HTTPTransport
  public init(transport: any HTTPTransport = URLSessionTransport()) { self.transport = transport }

  public func signIn(
    configuration: NativeOIDCConfiguration, presentationAnchor: UIWindow,
    prefersEphemeralSession: Bool = false, forceLogin: Bool = false
  ) async throws -> LoginResult {
    guard pending == nil, agent == nil else {
      throw MMGTError.invalidConfiguration("An OIDC authorization is already in progress")
    }
    let expected = UUID()
    generation = expected
    let browser = SystemBrowserAgent(
      redirectURL: configuration.redirectURL, window: presentationAnchor,
      ephemeral: prefersEphemeralSession)
    agent = browser
    defer { if generation == expected { agent = nil } }
    let http = HTTPClient(configuration: configuration.auth, transport: transport)
    let metadata: JSONValue = try await http.request(
      path: ["oidc", configuration.auth.appID, ".well-known", "openid-configuration"],
      authenticated: false)
    try Task.checkCancellation()
    guard generation == expected else { throw MMGTError.sessionChanged }
    let endpoints = try Self.validateDiscovery(metadata, configuration: configuration.auth)
    let service = OIDServiceConfiguration(
      authorizationEndpoint: endpoints.authorization, tokenEndpoint: endpoints.token,
      issuer: endpoints.issuer)
    // This initializer supplies secure state, nonce and PKCE S256. Public clients have no secret.
    let request = OIDAuthorizationRequest(
      configuration: service, clientId: configuration.clientID, clientSecret: nil,
      scopes: ["openid", "profile", "email", "offline_access"],
      redirectURL: configuration.redirectURL, responseType: OIDResponseTypeCode,
      additionalParameters: forceLogin ? ["prompt": "login"] : nil)
    try Task.checkCancellation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
          return
        }
        pending = continuation
        flow = OIDAuthState.authState(byPresenting: request, externalUserAgent: browser) {
          [weak self] state, error in
          // Convert Objective-C state to immutable Sendable values before crossing actors.
          let token = state?.lastTokenResponse
          let result = Self.loginResult(
            access: token?.accessToken, refresh: token?.refreshToken,
            idToken: token?.idToken, error: error)
          Task { @MainActor in self?.complete(result, expected: expected) }
        }
      }
    } onCancel: {
      Task { @MainActor in self.cancel() }
    }
  }
  // AppAuth validates issuer, audience, dates and nonce when an ID token is
  // present. Our openid flow requires it, so an OAuth-only response cannot
  // silently bypass those checks. Call only after AppAuth's code exchange.
  nonisolated static func loginResult(
    access: String?, refresh: String?, idToken: String?, error: (any Error)?
  ) -> Result<LoginResult, any Error> {
    if let error {
      return .failure(isCancellation(error) ? CancellationError() : error)
    }
    guard let access, !access.isEmpty, let refresh, !refresh.isEmpty,
      let idToken, !idToken.isEmpty
    else {
      return .failure(MMGTError.invalidResponse("OIDC did not return all required tokens"))
    }
    return .success(.authenticated(.init(accessToken: access, refreshToken: refresh)))
  }
  nonisolated static func isCancellation(_ error: any Error, depth: Int = 0) -> Bool {
    if error is CancellationError { return true }
    let value = error as NSError
    if value.domain == ASWebAuthenticationSessionError.errorDomain,
      value.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
    {
      return true
    }
    if value.domain == OIDGeneralErrorDomain,
      [
        OIDErrorCode.userCanceledAuthorizationFlow.rawValue,
        OIDErrorCode.programCanceledAuthorizationFlow.rawValue,
      ].contains(value.code)
    {
      return true
    }
    if depth < 3, let underlying = value.userInfo[NSUnderlyingErrorKey] as? any Error {
      return isCancellation(underlying, depth: depth + 1)
    }
    return false
  }
  nonisolated static func validateDiscovery(
    _ metadata: JSONValue, configuration: ServiceConfiguration
  ) throws -> (issuer: URL, authorization: URL, token: URL) {
    func endpoint(_ key: String, _ suffix: String?) throws -> URL {
      guard let text = metadata[key]?.string, let url = URL(string: text), url.scheme == "https",
        url.host == configuration.baseURL.host, url.port == configuration.baseURL.port,
        url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
      else { throw MMGTError.invalidResponse("OIDC discovery returned an untrusted endpoint") }
      let parts = url.path.split(separator: "/").map(String.init)
      let required = ["oidc", configuration.appID] + (suffix.map { [$0] } ?? [])
      let base = configuration.baseURL.path.split(separator: "/").map(String.init)
      // Auth serves its canonical issuer routes and the app-facing /auth alias.
      // Both must retain the configured origin and exact application identity.
      let paths = [required, base + required]
      guard paths.contains(parts) else {
        throw MMGTError.invalidResponse("OIDC endpoint belongs to a different application")
      }
      return url
    }
    return (
      try endpoint("issuer", nil), try endpoint("authorization_endpoint", "authorize"),
      try endpoint("token_endpoint", "token")
    )
  }
  private func complete(_ result: Result<LoginResult, any Error>, expected: UUID) {
    guard generation == expected else { return }
    flow = nil
    agent = nil
    let continuation = pending
    pending = nil
    continuation?.resume(with: result)
  }
  /// Forward onOpenURL/user-activity URLs here if the operating system routes a callback through the app.
  @discardableResult public func resume(_ url: URL) throws -> Bool {
    guard let flow else { return false }
    try flow.resumeExternalUserAgentFlow(url)
    return true
  }
  public func cancel() {
    generation = UUID()
    let active = flow
    flow = nil
    agent = nil
    let continuation = pending
    pending = nil
    active?.cancel()
    continuation?.resume(throwing: CancellationError())
  }
}

/// AppAuth's default iOS adapter still uses callbackURLScheme. This adapter supports exact HTTPS callbacks.
/// AppAuth invokes presentation/dismissal on the UI thread; preconcurrency enforces the MainActor boundary.
@MainActor
private final class SystemBrowserAgent: NSObject, @preconcurrency OIDExternalUserAgent,
  ASWebAuthenticationPresentationContextProviding
{
  private let redirectURL: URL
  private let window: UIWindow
  private let ephemeral: Bool
  private var browser: ASWebAuthenticationSession?
  private weak var flow: (any OIDExternalUserAgentSession)?
  init(redirectURL: URL, window: UIWindow, ephemeral: Bool) {
    self.redirectURL = redirectURL
    self.window = window
    self.ephemeral = ephemeral
  }
  func present(_ request: any OIDExternalUserAgentRequest, session: any OIDExternalUserAgentSession)
    -> Bool
  {
    guard browser == nil else { return false }
    flow = session
    let callback: ASWebAuthenticationSession.Callback
    if redirectURL.scheme == "https" {
      callback = .https(host: redirectURL.host!, path: redirectURL.path)
    } else {
      callback = .customScheme(redirectURL.scheme!)
    }
    let browser = ASWebAuthenticationSession(
      url: request.externalUserAgentRequestURL(), callback: callback
    ) { [weak self] url, error in
      Task { @MainActor in
        guard let self, let flow = self.flow else { return }
        self.browser = nil
        if let url {
          do { _ = try flow.resumeExternalUserAgentFlow(url) } catch {
            flow.failExternalUserAgentFlowWithError(error)
          }
        } else {
          flow.failExternalUserAgentFlowWithError(error ?? CancellationError())
        }
      }
    }
    browser.presentationContextProvider = self
    browser.prefersEphemeralWebBrowserSession = ephemeral
    self.browser = browser
    let started = browser.start()
    if !started {
      self.browser = nil
      flow = nil
    }
    return started
  }
  func dismiss(animated: Bool, completion: @escaping () -> Void) {
    browser?.cancel()
    browser = nil
    flow = nil
    completion()
  }
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    window
  }
}
