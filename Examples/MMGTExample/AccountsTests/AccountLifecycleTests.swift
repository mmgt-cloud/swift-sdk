import CryptoKit
import Foundation
import MMGTAuth
import MMGTCore
import Testing

private struct AccountFailure: Error, CustomStringConvertible {
  let description: String
}

private struct AccountConfiguration: Decodable, Sendable {
  let environment, appID, userID, email, password, replacementPassword, runID: String
  let authURL: URL
  static func load() throws -> Self {
    guard let encoded = ProcessInfo.processInfo.environment["MMGT_ACCOUNT_CONFIGURATION"],
      let data = Data(base64Encoded: encoded), data.count <= 65_536,
      let value = try? JSONDecoder().decode(Self.self, from: data),
      ["stage", "prod"].contains(value.environment),
      UUID(uuidString: value.appID) != nil, UUID(uuidString: value.userID) != nil,
      UUID(uuidString: value.runID) != nil,
      value.email.hasPrefix("account-sdk-"), value.email.hasSuffix("@example.invalid"),
      value.password.count >= 20, value.replacementPassword.count >= 20,
      value.password != value.replacementPassword
    else { throw AccountFailure(description: "Explicit owned account fixture required") }
    let host = value.environment == "stage" ? "api.stage.mmgt.cloud" : "api.mmgt.cloud"
    guard value.authURL.scheme == "https", value.authURL.host == host,
      value.authURL.path == "/auth", value.authURL.port == nil,
      value.authURL.user == nil, value.authURL.password == nil,
      value.authURL.query == nil, value.authURL.fragment == nil
    else { throw AccountFailure(description: "Account fixture crosses its environment") }
    return value
  }
}

private enum FixtureTOTP {
  static func code(secret: String, time: TimeInterval = Date().timeIntervalSince1970) throws
    -> String
  {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    var buffer = 0
    var bits = 0
    var key = Data()
    for character in secret.uppercased() {
      guard let value = alphabet.firstIndex(of: character) else {
        throw AccountFailure(description: "Invalid TOTP fixture encoding")
      }
      buffer = (buffer << 5) | value
      bits += 5
      if bits >= 8 {
        bits -= 8
        key.append(UInt8((buffer >> bits) & 255))
        buffer &= (1 << bits) - 1
      }
    }
    guard !key.isEmpty, buffer == 0 else {
      throw AccountFailure(description: "Invalid TOTP fixture length")
    }
    var counter = UInt64(time / 30).bigEndian
    let message = withUnsafeBytes(of: &counter) { Data($0) }
    let digest = Array(
      HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    let offset = Int(digest[19] & 15)
    let value =
      (UInt32(digest[offset] & 127) << 24) | (UInt32(digest[offset + 1]) << 16)
      | (UInt32(digest[offset + 2]) << 8) | UInt32(digest[offset + 3])
    return String(format: "%06u", value % 1_000_000)
  }
  static func nextCode(secret: String) async throws -> String {
    let wait = 31 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 30)
    try await Task.sleep(for: .seconds(wait))
    return try code(secret: secret)
  }
}

/// Runs only in the explicitly configured MMGTAccounts scheme, never the ordinary package suite.
@Suite(.serialized, .timeLimit(.minutes(5))) struct AccountLifecycleTests {
  @Test func fixtureTOTPMatchesKnownCounterVector() throws {
    #expect(try FixtureTOTP.code(secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", time: 59) == "287082")
  }

  @Test func realAccountSessionsTOTPRecoveryPasswordAndDeletion() async throws {
    let c = try AccountConfiguration.load()
    let config = try ServiceConfiguration(baseURL: c.authURL, appID: c.appID)
    let store = KeychainSessionStore(configuration: config)
    guard try store.load() == nil else {
      throw AccountFailure(
        description: "Account fixture already has persisted state; reconcile before running")
    }
    let session = AuthSession(configuration: config, store: store)
    let anonymous = AuthClient(configuration: config)
    var phase = "configuration"
    func require(_ value: Bool, _ reason: String) throws {
      guard value else { throw AccountFailure(description: reason) }
    }
    func denied(_ operation: () async throws -> Void) async throws {
      do {
        try await operation()
        throw AccountFailure(description: "Expected authorization rejection")
      } catch let error as APIError {
        try require([400, 401, 403].contains(error.status), "Unexpected rejection status")
      }
    }
    func challenge(password: String) async throws -> String {
      let result = try await session.authenticate {
        try await $0.login(input: .init(email: c.email, password: password))
      }
      guard case .requiresTwoFactor(let token, let method, _) = result,
        method == "totp", await session.identity == nil, try store.load() == nil
      else { throw AccountFailure(description: "MFA did not remain a restricted challenge") }
      return token
    }
    do {
      let methods = try await anonymous.get2FAMethods()
      try require(
        methods.totpEnabled && methods.availableMethods.contains("totp"), "Fixture must allow TOTP")
      _ = try await anonymous.getAppConfig()
      phase = "password-session-profile"
      _ = try await session.authenticate {
        try await $0.login(input: .init(email: c.email, password: c.password))
      }
      try require(await session.identity?.userID == c.userID, "Unexpected initial account")
      phase = "profile-update"
      let updated = try await session.performAccountOperation {
        try await $0.updateProfile(
          input: .init(firstName: "Native", lastName: "Fixture", locale: "en"))
      }
      try require(
        updated.id == c.userID && updated.firstName == "Native",
        "Profile update changed identity or fields")
      phase = "token-validation"
      _ = try await session.performAccountOperation { try await $0.validateToken() }
      phase = "activity-event-types"
      _ = try await session.performAccountOperation { try await $0.getActivityEventTypes() }
      phase = "activity-list"
      _ = try await session.performAccountOperation {
        try await $0.listActivityLogs(page: 1, limit: 10)
      }
      phase = "session-list"
      let before = try await session.performAccountOperation { try await $0.listSessions() }
      try require(before.sessions.contains(where: \.isCurrent), "Current session absent")
      print("MMGT account acceptance: profile and session reads passed")

      phase = "session-revocation-refresh"
      guard
        case .authenticated(let secondary) = try await anonymous.login(
          input: .init(email: c.email, password: c.password))
      else { throw AccountFailure(description: "Secondary owned session not created") }
      let second = AuthClient(configuration: config, tokenProvider: { secondary.accessToken })
      _ = try await second.getProfile()
      _ = try await session.performAccountOperation { try await $0.revokeOtherSessions() }
      try await denied { _ = try await second.getProfile() }
      _ = try await session.refreshToken()
      try require(
        try store.load()?.identity.userID == c.userID, "Refresh did not preserve persisted identity"
      )
      let remaining = try await session.performAccountOperation { try await $0.listSessions() }
      try require(
        remaining.sessions.count == 1 && remaining.sessions[0].isCurrent,
        "Other sessions remain active")
      print("MMGT account acceptance: session revocation and refresh passed")

      phase = "totp-enrollment"
      let setup = try await session.performAccountOperation { try await $0.generate2FA() }
      let setupCode = try FixtureTOTP.code(secret: setup.secret)
      _ = try await session.performAccountOperation { try await $0.verify2FASetup(code: setupCode) }
      let enabled = try await session.performAccountOperation { try await $0.enable2FA() }
      try require(enabled.recoveryCodes.count >= 2, "Recovery codes absent")
      try await session.logout()
      let temporary = try await challenge(password: c.password)
      let limited = AuthClient(configuration: config, tokenProvider: { temporary })
      try await denied { _ = try await limited.getProfile() }
      let code = try await FixtureTOTP.nextCode(secret: setup.secret)
      let wrong = String(code.first == "0" ? "1" : "0") + code.dropFirst()
      try await denied {
        _ = try await anonymous.verify2FALogin(input: .init(tempToken: temporary, code: wrong))
      }
      _ = try await session.authenticate {
        try await $0.verify2FALogin(input: .init(tempToken: temporary, code: code))
      }
      try require(await session.identity?.userID == c.userID, "TOTP authenticated another account")
      print("MMGT account acceptance: TOTP enrollment, restricted challenge and login passed")

      phase = "recovery-code-single-use"
      try await session.logout()
      let firstChallenge = try await challenge(password: c.password)
      _ = try await session.authenticate {
        try await $0.verify2FALogin(
          input: .init(tempToken: firstChallenge, recoveryCode: enabled.recoveryCodes[0]))
      }
      try require(
        await session.identity?.userID == c.userID, "Recovery authenticated another account")
      try await session.logout()
      let nextChallenge = try await challenge(password: c.password)
      try await denied {
        _ = try await anonymous.verify2FALogin(
          input: .init(tempToken: nextChallenge, recoveryCode: enabled.recoveryCodes[0]))
      }
      _ = try await session.authenticate {
        try await $0.verify2FALogin(
          input: .init(tempToken: nextChallenge, recoveryCode: enabled.recoveryCodes[1]))
      }
      let disableCode = try await FixtureTOTP.nextCode(secret: setup.secret)
      _ = try await session.performAccountOperation { try await $0.disable2FA(code: disableCode) }
      print("MMGT account acceptance: recovery replay rejection and MFA disable passed")

      phase = "password-change"
      let retained = await session.tokenProvider
      let oldClient = AuthClient(configuration: config, tokenProvider: retained)
      _ = try await session.performAccountOperation {
        try await $0.updatePassword(
          input: .init(currentPassword: c.password, newPassword: c.replacementPassword))
      }
      try await denied { _ = try await oldClient.getProfile() }
      try await session.signOutLocally()
      try await denied {
        _ = try await anonymous.login(input: .init(email: c.email, password: c.password))
      }
      _ = try await session.authenticate {
        try await $0.login(input: .init(email: c.email, password: c.replacementPassword))
      }
      try require(
        await session.identity?.userID == c.userID, "New password authenticated another account")
      let proof = try await session.performAccountOperation {
        try await $0.reauthenticateWithPassword(currentPassword: c.replacementPassword)
      }
      try require(!proof.token.isEmpty && proof.expiresIn > 0, "Password reauthentication absent")
      print(
        "MMGT account acceptance: password rotation, old-session rejection and reauthentication passed"
      )

      phase = "account-deletion"
      let beforeDeletion = AuthClient(
        configuration: config, tokenProvider: await session.tokenProvider)
      _ = try await session.performAccountOperation {
        try await $0.deleteAccount(
          input: .init(password: c.replacementPassword, confirmDeletion: true))
      }
      try await denied { _ = try await beforeDeletion.getProfile() }
      try await session.signOutLocally()
      try require(try store.load() == nil, "Deleted account remained persisted")
      print("MMGT account acceptance: account deletion and local credential cleanup passed")
    } catch {
      try? await session.signOutLocally()
      let code: String
      if let api = error as? APIError {
        code = "HTTP " + String(api.status)
      } else if let keychain = error as? KeychainError {
        code = "Keychain OSStatus " + String(keychain.status)
      } else if error is CancellationError {
        code = "cancelled"
      } else if let safe = error as? AccountFailure {
        code = safe.description
      } else {
        code = "local-or-contract-error"
      }
      throw AccountFailure(
        description: "Account acceptance failed at " + phase + " [" + code
          + "]; no retry; reconcile owned fixture")
    }
  }
}
