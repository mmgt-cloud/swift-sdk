import Foundation
import MMGTAuth
import MMGTCore
import Testing
import UIKit

private struct NativeFailure: Error, CustomStringConvertible {
  let description: String
}

private struct NativeConfiguration: Decodable, Sendable {
  let environment, appID, userID, email, password, runID: String
  let teamID, bundleID, relyingPartyID, clientID: String
  let authURL, redirectURL: URL

  static func load() throws -> Self {
    guard let text = ProcessInfo.processInfo.environment["MMGT_NATIVE_CONFIGURATION"],
      let bytes = Data(base64Encoded: text), bytes.count <= 65_536,
      let value = try? JSONDecoder().decode(Self.self, from: bytes),
      ["stage", "prod"].contains(value.environment),
      UUID(uuidString: value.appID) != nil, UUID(uuidString: value.userID) != nil,
      UUID(uuidString: value.runID) != nil, value.email.hasSuffix("@example.invalid"),
      !value.password.isEmpty, !value.clientID.isEmpty,
      value.bundleID == Bundle.main.bundleIdentifier
    else {
      throw NativeFailure(description: "Explicit owned native fixture configuration is required")
    }
    let domain = value.environment == "stage" ? "stage.mmgt.cloud" : "mmgt.cloud"
    guard value.relyingPartyID == domain, value.authURL.host == "api." + domain,
      value.authURL.path == "/auth", value.redirectURL.host == domain,
      value.redirectURL.path.hasPrefix("/native/"), !value.redirectURL.path.contains("*")
    else { throw NativeFailure(description: "Native fixture crosses its application environment") }
    for url in [value.authURL, value.redirectURL] {
      guard url.scheme == "https", url.user == nil, url.password == nil,
        url.query == nil, url.fragment == nil, url.port == nil
      else { throw NativeFailure(description: "Native fixture requires exact HTTPS URLs") }
    }
    return value
  }
}

/// Requires real system passkey interaction on a signed physical iPhone. This
/// suite is intentionally absent from SPM and ordinary synthetic-device tests.
@Suite(.serialized, .timeLimit(.minutes(10)))
struct NativeAuthenticationTests {
  @Test @MainActor func passkeyAndSystemBrowserUniversalLink() async throws {
    #if targetEnvironment(simulator)
      throw NativeFailure(description: "Physical-device acceptance cannot run on a simulator")
    #else
      let c = try NativeConfiguration.load()
      let configuration = try ServiceConfiguration(baseURL: c.authURL, appID: c.appID)
      let session = AuthSession(configuration: configuration)
      var phase = "association"
      do {
        let association = HTTPClient(
          configuration: try .init(
            baseURL: URL(string: "https://" + c.relyingPartyID)!, appID: c.appID))
        let aasa: JSONValue = try await association.request(
          path: [".well-known", "apple-app-site-association"], authenticated: false)
        let application = c.teamID + "." + c.bundleID
        guard case .array(let credentials) = aasa["webcredentials"]?["apps"],
          credentials.contains(.string(application)),
          case .array(let links) = aasa["applinks"]?["details"],
          links.contains(where: { detail in
            guard case .array(let apps) = detail["appIDs"],
              case .array(let components) = detail["components"]
            else { return false }
            return apps.contains(.string(application))
              && components.contains(where: { $0["/"]?.string == c.redirectURL.path })
          })
        else {
          throw NativeFailure(
            description: "Public AASA does not contain the exact approved registration")
        }

        phase = "password-fixture"
        let login = try await session.authenticate {
          try await $0.login(input: .init(email: c.email, password: c.password))
        }
        guard case .authenticated = login, await session.identity?.userID == c.userID else {
          throw NativeFailure(
            description: "Fixture password authentication did not identify its owner")
        }
        let before = try await session.performAccountOperation { try await $0.listPasskeys() }
        guard before.passkeys.isEmpty else {
          throw NativeFailure(
            description:
              "Use a fresh owned fixture; never register again after an uncertain attempt")
        }
        guard
          let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow)
        else { throw NativeFailure(description: "No active native presentation window") }
        let passkeys = try NativePasskeys(
          relyingPartyID: c.relyingPartyID, presentationAnchor: window)
        phase = "passkey-registration"
        print("MMGT native acceptance: confirm passkey creation on this iPhone")
        let name = "SDK native " + c.runID
        _ = try await session.performAccountOperation {
          try await passkeys.register(name: name, client: $0)
        }
        let registered = try await session.performAccountOperation { try await $0.listPasskeys() }
        guard registered.passkeys.count == 1, let passkey = registered.passkeys.first,
          passkey.name == name
        else {
          throw NativeFailure(
            description: "The created passkey is not recorded for the expected account")
        }
        try await session.logout()

        phase = "native-passkey-sign-in"
        print("MMGT native acceptance: confirm native passkey sign-in")
        let native = try await session.authenticate { try await passkeys.signIn(client: $0) }
        guard case .authenticated = native, await session.identity?.userID == c.userID else {
          throw NativeFailure(
            description: "Native passkey sign-in did not identify the fixture owner")
        }
        phase = "passkey-reauthentication"
        print("MMGT native acceptance: confirm passkey reauthentication")
        let proof = try await session.performAccountOperation {
          try await passkeys.reauthenticate(client: $0)
        }
        guard !proof.token.isEmpty else {
          throw NativeFailure(description: "Passkey reauthentication returned no proof")
        }
        try await session.logout()

        phase = "oidc-system-browser"
        print(
          "MMGT native acceptance: select passkey sign-in in the system browser and complete consent"
        )
        let authorizer = OIDCAuthorizer()
        let oidc = try NativeOIDCConfiguration(
          auth: configuration, clientID: c.clientID, redirectURL: c.redirectURL)
        let browser = try await session.authenticate { _ in
          try await authorizer.signIn(
            configuration: oidc, presentationAnchor: window,
            prefersEphemeralSession: true, forceLogin: true)
        }
        guard case .authenticated = browser, await session.identity?.userID == c.userID else {
          throw NativeFailure(
            description: "HTTPS browser callback did not authenticate the fixture owner")
        }
        phase = "oidc-refresh-profile"
        _ = try await session.refreshToken()
        let profile = try await session.performAccountOperation { try await $0.getProfile() }
        guard profile.id == c.userID else {
          throw NativeFailure(description: "OIDC refresh changed the account identity")
        }
        phase = "credential-cleanup"
        _ = try await session.performAccountOperation { try await $0.deletePasskey(id: passkey.id) }
        let remaining = try await session.performAccountOperation { try await $0.listPasskeys() }
        guard remaining.passkeys.isEmpty else {
          throw NativeFailure(description: "Native fixture credential cleanup failed")
        }
        try await session.logout()
        print(
          "MMGT native acceptance: passkey, HTTPS OIDC callback, refresh and server credential cleanup passed"
        )
      } catch {
        try? await session.signOutLocally()
        // Raw browser/provider error text may include an authorization URL.
        // Preserve phase and HTTP status, never tokens, codes or credentials.
        let status = (error as? APIError).map { " HTTP " + String($0.status) } ?? ""
        throw NativeFailure(
          description: "Native acceptance failed at " + phase + status
            + "; no retry; reconcile the owned fixture")
      }
    #endif
  }
}
