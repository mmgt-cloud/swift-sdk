import AuthenticationServices
import Foundation
import MMGTCore
import UIKit

public enum Base64URL {
  public static func encode(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
      of: "/", with: "_"
    ).replacingOccurrences(of: "=", with: "")
  }
  public static func decode(_ value: String) throws -> Data {
    guard !value.isEmpty,
      value.unicodeScalars.allSatisfy(
        CharacterSet(
          charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        ).contains), value.count % 4 != 1
    else { throw MMGTError.invalidResponse("Invalid WebAuthn base64url") }
    var source = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    source += String(repeating: "=", count: (4 - source.count % 4) % 4)
    guard let data = Data(base64Encoded: source), encode(data) == value else {
      throw MMGTError.invalidResponse("Invalid WebAuthn base64url")
    }
    return data
  }
}

/// System passkey UI. The app must have the matching webcredentials Associated Domain and AASA entry.
@MainActor
public final class NativePasskeys: NSObject, ASAuthorizationControllerDelegate,
  ASAuthorizationControllerPresentationContextProviding
{
  public let relyingPartyID: String
  private let window: UIWindow
  private let startRequest: @MainActor (ASAuthorizationController) -> Void
  private var controller: ASAuthorizationController?
  private(set) var ceremony: UUID?
  private var pending: CheckedContinuation<JSONValue, any Error>?

  public convenience init(relyingPartyID: String, presentationAnchor: UIWindow) throws {
    try self.init(
      relyingPartyID: relyingPartyID, presentationAnchor: presentationAnchor,
      startRequest: { $0.performRequests() })
  }
  init(
    relyingPartyID: String, presentationAnchor: UIWindow,
    startRequest: @escaping @MainActor (ASAuthorizationController) -> Void
  ) throws {
    guard !relyingPartyID.isEmpty, !relyingPartyID.contains("/"), !relyingPartyID.contains(":")
    else { throw MMGTError.invalidConfiguration("A WebAuthn RP hostname is required") }
    self.relyingPartyID = relyingPartyID
    window = presentationAnchor
    self.startRequest = startRequest
    super.init()
  }
  public func register(name: String, client: AuthClient) async throws -> MessageResponse {
    let options = try await client.beginPasskeyRegistration()
    let credential = try await createCredential(options: options)
    return try await client.finishPasskeyRegistration(name: name, credential: credential)
  }
  public func signIn(client: AuthClient) async throws -> LoginResult {
    let begin = try await client.beginPasswordlessLogin()
    let credential = try await getCredential(options: begin.options)
    return try await client.finishPasswordlessLogin(
      sessionID: begin.sessionId, credential: credential)
  }
  /// Register a credential first, then verify it before activating passkey MFA.
  /// Save the returned recovery codes and complete a fresh MFA sign-in afterwards.
  public func enableTwoFactor(client: AuthClient) async throws -> TwoFAEnableResponse {
    let options = try await client.beginPasskeyEnrollment()
    let credential = try await getCredential(options: options)
    return try await client.finishPasskeyEnrollment(credential: credential)
  }
  public func verifyTwoFactor(tempToken: String, client: AuthClient) async throws -> LoginResult {
    let options = try await client.beginPasskey2FA(tempToken: tempToken)
    let credential = try await getCredential(options: options)
    return try await client.finishPasskey2FA(tempToken: tempToken, credential: credential)
  }
  public func reauthenticate(client: AuthClient) async throws -> ReauthenticationProof {
    let options = try await client.beginPasskeyReauthentication()
    let credential = try await getCredential(options: options)
    return try await client.finishPasskeyReauthentication(credential: credential)
  }
  public func createCredential(options: JSONValue) async throws -> JSONValue {
    try await perform(registrationRequest(options: options))
  }
  func registrationRequest(options: JSONValue) throws
    -> ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest
  {
    guard let key = options["publicKey"], key["rp"]?["id"]?.string == relyingPartyID,
      let challenge = key["challenge"]?.string, let user = key["user"],
      let name = user["name"]?.string, let id = user["id"]?.string
    else {
      throw MMGTError.invalidResponse(
        "WebAuthn registration options do not match the configured RP")
    }
    let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
      relyingPartyIdentifier: relyingPartyID)
    let request = provider.createCredentialRegistrationRequest(
      challenge: try Base64URL.decode(challenge), name: name, userID: try Base64URL.decode(id))
    request.displayName = user["displayName"]?.string
    request.userVerificationPreference = preference(
      key["authenticatorSelection"]?["userVerification"]?.string)
    request.excludedCredentials = try descriptors(key["excludeCredentials"])
    return request
  }
  public func getCredential(options: JSONValue) async throws -> JSONValue {
    try await perform(assertionRequest(options: options))
  }
  func assertionRequest(options: JSONValue) throws
    -> ASAuthorizationPlatformPublicKeyCredentialAssertionRequest
  {
    guard let key = options["publicKey"], let challenge = key["challenge"]?.string,
      key["rpId"]?.string == nil || key["rpId"]?.string == relyingPartyID
    else {
      throw MMGTError.invalidResponse("WebAuthn assertion options do not match the configured RP")
    }
    let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
      relyingPartyIdentifier: relyingPartyID)
    let request = provider.createCredentialAssertionRequest(
      challenge: try Base64URL.decode(challenge))
    request.allowedCredentials = try descriptors(key["allowCredentials"])
    request.userVerificationPreference = preference(key["userVerification"]?.string)
    return request
  }
  private func descriptors(_ value: JSONValue?) throws
    -> [ASAuthorizationPlatformPublicKeyCredentialDescriptor]
  {
    guard let value else { return [] }
    guard case .array(let entries) = value else {
      throw MMGTError.invalidResponse("Invalid WebAuthn credential descriptors")
    }
    return try entries.map {
      guard $0["type"]?.string == "public-key", let id = $0["id"]?.string else {
        throw MMGTError.invalidResponse("Invalid WebAuthn credential descriptor")
      }
      return .init(credentialID: try Base64URL.decode(id))
    }
  }
  private func preference(_ value: String?)
    -> ASAuthorizationPublicKeyCredentialUserVerificationPreference
  {
    switch value {
    case "required": .required
    case "discouraged": .discouraged
    default: .preferred
    }
  }
  func perform(_ request: ASAuthorizationRequest) async throws -> JSONValue {
    guard pending == nil else {
      throw MMGTError.invalidConfiguration("A passkey request is already in progress")
    }
    try Task.checkCancellation()
    let controller = ASAuthorizationController(authorizationRequests: [request])
    let expected = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
          return
        }
        pending = continuation
        self.controller = controller
        ceremony = expected
        controller.delegate = self
        controller.presentationContextProvider = self
        startRequest(controller)
      }
    } onCancel: {
      Task { @MainActor in self.cancel(ceremony: expected) }
    }
  }
  // The cancellation handler captures the ceremony whose operation was canceled.
  func cancel(ceremony: UUID) {
    guard self.ceremony == ceremony else { return }
    cancel()
  }
  public func cancel() {
    let active = controller
    controller = nil
    ceremony = nil
    let continuation = pending
    pending = nil
    active?.cancel()
    continuation?.resume(throwing: CancellationError())
  }
  public func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor
  { window }
  public func authorizationController(
    controller: ASAuthorizationController,
    didCompleteWithAuthorization authorization: ASAuthorization
  ) {
    guard self.controller === controller else { return }
    do {
      let result: JSONValue
      if let credential = authorization.credential
        as? ASAuthorizationPlatformPublicKeyCredentialRegistration
      {
        guard let attestation = credential.rawAttestationObject else {
          throw MMGTError.invalidResponse("Missing passkey attestation")
        }
        result = Self.registrationJSON(
          id: credential.credentialID, clientData: credential.rawClientDataJSON,
          attestation: attestation)
      } else if let credential = authorization.credential
        as? ASAuthorizationPlatformPublicKeyCredentialAssertion
      {
        result = Self.assertionJSON(
          id: credential.credentialID, clientData: credential.rawClientDataJSON,
          authenticatorData: credential.rawAuthenticatorData, signature: credential.signature,
          userID: credential.userID)
      } else {
        throw MMGTError.invalidResponse("Unexpected credential type")
      }
      self.controller = nil
      ceremony = nil
      let continuation = pending
      pending = nil
      continuation?.resume(returning: result)
    } catch {
      self.controller = nil
      ceremony = nil
      let continuation = pending
      pending = nil
      continuation?.resume(throwing: error)
    }
  }
  public func authorizationController(
    controller: ASAuthorizationController, didCompleteWithError error: any Error
  ) {
    guard self.controller === controller else { return }
    self.controller = nil
    ceremony = nil
    let continuation = pending
    pending = nil
    if (error as? ASAuthorizationError)?.code == .canceled {
      continuation?.resume(throwing: CancellationError())
    } else {
      continuation?.resume(throwing: error)
    }
  }
  public nonisolated static func registrationJSON(id: Data, clientData: Data, attestation: Data)
    -> JSONValue
  {
    [
      "id": .string(Base64URL.encode(id)), "rawId": .string(Base64URL.encode(id)),
      "type": "public-key", "authenticatorAttachment": "platform",
      "clientExtensionResults": .object([:]),
      "response": [
        "attestationObject": .string(Base64URL.encode(attestation)),
        "clientDataJSON": .string(Base64URL.encode(clientData)), "transports": ["internal"],
      ],
    ]
  }
  public nonisolated static func assertionJSON(
    id: Data, clientData: Data, authenticatorData: Data, signature: Data, userID: Data
  ) -> JSONValue {
    [
      "id": .string(Base64URL.encode(id)), "rawId": .string(Base64URL.encode(id)),
      "type": "public-key", "authenticatorAttachment": "platform",
      "clientExtensionResults": .object([:]),
      "response": [
        "authenticatorData": .string(Base64URL.encode(authenticatorData)),
        "clientDataJSON": .string(Base64URL.encode(clientData)),
        "signature": .string(Base64URL.encode(signature)),
        "userHandle": userID.isEmpty ? .null : .string(Base64URL.encode(userID)),
      ],
    ]
  }
}
