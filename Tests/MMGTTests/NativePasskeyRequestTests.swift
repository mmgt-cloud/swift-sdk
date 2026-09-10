import AuthenticationServices
import Foundation
import MMGTCore
import Testing
import UIKit

@testable import MMGTAuth

@MainActor private final class PasskeyLaunches {
  var controllers: [ASAuthorizationController] = []
  var observers: [(Int, CheckedContinuation<Void, Never>)] = []
  func start(_ controller: ASAuthorizationController) {
    controllers.append(controller)
    let ready = observers.filter { controllers.count >= $0.0 }
    observers.removeAll { controllers.count >= $0.0 }
    for (_, waiter) in ready { waiter.resume() }
  }
  func wait(_ count: Int) async {
    if controllers.count >= count { return }
    await withCheckedContinuation { observers.append((count, $0)) }
  }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct NativePasskeyRequestTests {
  func options(_ name: String) throws -> JSONValue {
    let value: JSONValue = try SharedWireContractTests().decode(name)
    return try #require(value["options"])
  }
  @Test func requestsPreserveServerChallengeRPAndCredentialBytes() throws {
    let helper = try NativePasskeys(
      relyingPartyID: "login.example.invalid", presentationAnchor: UIWindow(frame: .zero))
    let creation = try helper.registrationRequest(options: options("auth-creation"))
    #expect(creation.challenge == Data([0, 1, 2, 3, 254, 255]))
    #expect(creation.userID == Data([1, 2, 3, 255]))
    #expect(
      creation.name == "synthetic@example.invalid" && creation.displayName == "Synthetic user")
    #expect(creation.relyingPartyIdentifier == "login.example.invalid")
    #expect(creation.userVerificationPreference == .preferred)
    #expect((creation.excludedCredentials ?? []).map(\.credentialID) == [Data([1, 2, 3, 255])])
    let assertion = try helper.assertionRequest(options: options("auth-assertion"))
    #expect(assertion.challenge == creation.challenge)
    #expect(assertion.relyingPartyIdentifier == creation.relyingPartyIdentifier)
    #expect(assertion.userVerificationPreference == .required)
    #expect(
      assertion.allowedCredentials.map(\.credentialID)
        == (creation.excludedCredentials ?? []).map(\.credentialID))
  }

  @Test func wrongRPAndMalformedCredentialsCannotLaunchSystemUI() async throws {
    let launches = PasskeyLaunches()
    let helper = try NativePasskeys(
      relyingPartyID: "other.example.invalid", presentationAnchor: UIWindow(frame: .zero),
      startRequest: launches.start)
    await #expect(throws: MMGTError.self) {
      _ = try await helper.createCredential(options: options("auth-creation"))
    }
    await #expect(throws: MMGTError.self) {
      _ = try await helper.getCredential(options: options("auth-assertion"))
    }
    let matching = try NativePasskeys(
      relyingPartyID: "login.example.invalid", presentationAnchor: UIWindow(frame: .zero),
      startRequest: launches.start)
    for bad: JSONValue in ["AAE=", "AAE\r\n", "A", "AB"] {
      await #expect(throws: MMGTError.self) {
        _ = try await matching.getCredential(options: [
          "publicKey": ["rpId": "login.example.invalid", "challenge": bad]
        ])
      }
    }
    await #expect(throws: MMGTError.self) {
      _ = try await matching.getCredential(options: [
        "publicKey": ["challenge": "AAE", "allowCredentials": [["type": "wrong", "id": "AAE"]]]
      ])
    }
    #expect(launches.controllers.isEmpty)
  }

  @Test func delayedCancellationAndDelegateFromOldCeremonyCannotCancelNewOne() async throws {
    let launches = PasskeyLaunches()
    let helper = try NativePasskeys(
      relyingPartyID: "login.example.invalid", presentationAnchor: UIWindow(frame: .zero),
      startRequest: launches.start)
    let first = Task { try await helper.getCredential(options: options("auth-assertion")) }
    await launches.wait(1)
    let old = launches.controllers[0]
    let oldCeremony = try #require(helper.ceremony)
    helper.authorizationController(
      controller: old, didCompleteWithError: MMGTError.unsupported("first finished"))
    await #expect(throws: MMGTError.unsupported("first finished")) { _ = try await first.value }
    let second = Task { try await helper.getCredential(options: options("auth-assertion")) }
    await launches.wait(2)
    // Deliver the exact queued cancellation action after the replacement starts.
    // No OS prompt or scheduler timing is needed to exercise this ordering.
    helper.cancel(ceremony: oldCeremony)
    helper.authorizationController(
      controller: old, didCompleteWithError: MMGTError.unsupported("stale delegate"))
    helper.authorizationController(
      controller: launches.controllers[1],
      didCompleteWithError: MMGTError.unsupported("second finished"))
    await #expect(throws: MMGTError.unsupported("second finished")) { _ = try await second.value }
  }

  @Test func cancelledNativeWrappersNeverSubmitCredentialFinish() async throws {
    for operation in ["register", "login", "mfa", "enroll", "reauth"] {
      let launches = PasskeyLaunches()
      let helper = try NativePasskeys(
        relyingPartyID: "login.example.invalid", presentationAnchor: UIWindow(frame: .zero),
        startRequest: launches.start)
      let fixture =
        operation == "register"
        ? "auth-creation" : operation == "login" ? "auth-passkeylogin" : "auth-assertion"
      let transport = RecordingTransport([
        .init(data: try SharedWireContractTests().data(fixture), status: 200)
      ])
      let client = try AuthMFAContractTests().client(transport)
      let task = Task {
        switch operation {
        case "register": _ = try await helper.register(name: "Synthetic", client: client)
        case "login": _ = try await helper.signIn(client: client)
        case "mfa":
          _ = try await helper.verifyTwoFactor(tempToken: "synthetic-temp", client: client)
        case "enroll": _ = try await helper.enableTwoFactor(client: client)
        default: _ = try await helper.reauthenticate(client: client)
        }
      }
      await launches.wait(1)
      helper.cancel()
      await #expect(throws: CancellationError.self) { try await task.value }
      #expect(await transport.requests.count == 1)
    }
  }
}
