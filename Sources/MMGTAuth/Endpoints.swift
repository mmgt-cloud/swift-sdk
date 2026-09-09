// Direct Auth HTTP operations. Lifecycle and native authorization are implemented separately.
import Foundation
import MMGTCore

extension AuthClient {
  public func register(input: RegisterRequest) async throws -> MessageResponse {
    try await http.request(
      path: ["register"], method: "POST", body: try .encoding(input), authenticated: false)
  }

  public func forgotPassword(input: ForgotPasswordRequest) async throws -> MessageResponse {
    try await http.request(
      path: ["forgot-password"], method: "POST", body: try .encoding(input), authenticated: false)
  }

  public func resetPassword(input: ResetPasswordRequest) async throws -> MessageResponse {
    try await http.request(
      path: ["reset-password"], method: "POST", body: try .encoding(input), authenticated: false)
  }

  public func verifyEmail(token: String) async throws -> MessageResponse {
    try await http.request(
      path: ["verify-email"], query: [.init(name: "token", value: token)], authenticated: false)
  }

  public func resendVerification(input: ResendVerificationRequest) async throws -> MessageResponse {
    try await http.request(
      path: ["resend-verification"], method: "POST", body: try .encoding(input),
      authenticated: false)
  }

  public func requestMagicLink(input: MagicLinkRequest) async throws -> MessageResponse {
    try await http.request(
      path: ["magic-link", "request"], method: "POST", body: try .encoding(input),
      authenticated: false)
  }

  public func getProfile() async throws -> UserResponse {
    try await http.request(path: ["profile"], authenticated: true)
  }

  public func updateProfile(input: UpdateProfileRequest) async throws -> UserResponse {
    try await http.request(
      path: ["profile"], method: "PUT", body: try .encoding(input), authenticated: true)
  }

  public func updateEmail(input: UpdateEmailRequest) async throws -> MessageResponse {
    try await http.request(
      path: ["profile", "email"], method: "PUT", body: try .encoding(input), authenticated: true)
  }

  public func updatePassword(input: UpdatePasswordRequest) async throws -> MessageResponse {
    try await http.request(
      path: ["profile", "password"], method: "PUT", body: try .encoding(input), authenticated: true)
  }

  public func setPassword(input: SetPasswordRequest) async throws -> MessageResponse {
    try await http.request(
      path: ["profile", "set-password"], method: "POST", body: try .encoding(input),
      authenticated: true)
  }

  public func validateToken() async throws -> ValidateTokenResponse {
    try await http.request(path: ["validate"], authenticated: true)
  }

  public func listSocialAccounts() async throws -> SocialAccountListResponse {
    try await http.request(path: ["profile", "social-accounts"], authenticated: true)
  }

  public func unlinkSocialAccount(id: String) async throws -> MessageResponse {
    try await http.request(
      path: ["profile", "social-accounts", id], method: "DELETE", authenticated: true)
  }

  public func generate2FA() async throws -> TwoFASetupResponse {
    try await http.request(path: ["2fa", "generate"], method: "POST", authenticated: true)
  }

  public func verify2FASetup(code: String) async throws -> MessageResponse {
    try await http.request(
      path: ["2fa", "verify-setup"], method: "POST", body: ["code": try .encoding(code)],
      authenticated: true)
  }

  public func enable2FA() async throws -> TwoFAEnableResponse {
    try await http.request(path: ["2fa", "enable"], method: "POST", authenticated: true)
  }

  public func disable2FA(code: String) async throws -> MessageResponse {
    try await http.request(
      path: ["2fa", "disable"], method: "POST", body: ["code": try .encoding(code)],
      authenticated: true)
  }

  public func generateRecoveryCodes(code: String) async throws -> TwoFARecoveryCodesResponse {
    try await http.request(
      path: ["2fa", "recovery-codes"], method: "POST", body: ["code": try .encoding(code)],
      authenticated: true)
  }

  public func enableEmail2FA() async throws -> TwoFAEnableResponse {
    try await http.request(path: ["2fa", "email", "enable"], method: "POST", authenticated: true)
  }

  public func resendEmail2FACode(tempToken: String) async throws -> MessageResponse {
    try await http.request(
      path: ["2fa", "email", "resend"], method: "POST",
      body: ["temp_token": try .encoding(tempToken)], authenticated: false)
  }

  public func enableSMS2FA() async throws -> TwoFAEnableResponse {
    try await http.request(path: ["2fa", "sms", "enable"], method: "POST", authenticated: true)
  }

  public func resendSMS2FACode(tempToken: String) async throws -> MessageResponse {
    try await http.request(
      path: ["2fa", "sms", "resend"], method: "POST",
      body: ["temp_token": try .encoding(tempToken)], authenticated: false)
  }

  public func enableBackupEmail2FA() async throws -> TwoFAEnableResponse {
    try await http.request(
      path: ["2fa", "backup-email", "enable"], method: "POST", authenticated: true)
  }

  public func disableBackupEmail2FA(code: String) async throws -> MessageResponse {
    try await http.request(
      path: ["2fa", "backup-email", "disable"], method: "POST", body: ["code": try .encoding(code)],
      authenticated: true)
  }

  public func resendBackupEmail2FACode(tempToken: String) async throws -> MessageResponse {
    try await http.request(
      path: ["2fa", "backup-email", "resend"], method: "POST",
      body: ["temp_token": try .encoding(tempToken)], authenticated: false)
  }

  public func get2FAMethods() async throws -> TwoFAMethodsResponse {
    try await http.request(path: ["2fa", "methods"], authenticated: false)
  }

  public func addBackupEmail(input: AddBackupEmailRequest) async throws -> MessageResponse {
    try await http.request(
      path: ["2fa", "backup-email"], method: "POST", body: try .encoding(input), authenticated: true
    )
  }

  public func removeBackupEmail() async throws -> MessageResponse {
    try await http.request(path: ["2fa", "backup-email"], method: "DELETE", authenticated: true)
  }

  public func getBackupEmailStatus() async throws -> BackupEmailStatusResponse {
    try await http.request(path: ["2fa", "backup-email", "status"], authenticated: true)
  }

  public func verifyBackupEmail(token: String) async throws -> MessageResponse {
    try await http.request(
      path: ["2fa", "backup-email", "verify"], query: [.init(name: "token", value: token)],
      authenticated: false)
  }

  public func addPhone(input: AddPhoneRequest) async throws -> MessageResponse {
    try await http.request(
      path: ["phone"], method: "POST", body: try .encoding(input), authenticated: true)
  }

  public func verifyPhone(input: VerifyPhoneRequest) async throws -> MessageResponse {
    try await http.request(
      path: ["phone", "verify"], method: "POST", body: try .encoding(input), authenticated: true)
  }

  public func removePhone() async throws -> MessageResponse {
    try await http.request(path: ["phone"], method: "DELETE", authenticated: true)
  }

  public func getPhoneStatus() async throws -> PhoneStatusResponse {
    try await http.request(path: ["phone", "status"], authenticated: true)
  }

  public func listTrustedDevices() async throws -> TrustedDevicesListResponse {
    try await http.request(path: ["2fa", "trusted-devices"], authenticated: true)
  }

  public func revokeTrustedDevice(id: String) async throws -> MessageResponse {
    try await http.request(
      path: ["2fa", "trusted-devices", id], method: "DELETE", authenticated: true)
  }

  public func revokeAllTrustedDevices() async throws -> MessageResponse {
    try await http.request(path: ["2fa", "trusted-devices"], method: "DELETE", authenticated: true)
  }

  public func finishPasskeyRegistration(name: String, credential: JSONValue) async throws
    -> MessageResponse
  {
    try await http.request(
      path: ["passkey", "register", "finish"], method: "POST",
      body: ["name": try .encoding(name), "credential": try .encoding(credential)],
      authenticated: true)
  }

  public func finishPasskeyEnrollment(credential: JSONValue) async throws -> TwoFAEnableResponse {
    try await http.request(
      path: ["2fa", "passkey", "setup", "finish"], method: "POST",
      body: ["credential": try .encoding(credential)], authenticated: true)
  }

  public func beginPasswordlessLogin() async throws -> PasskeyLoginBeginResponse {
    try await http.request(
      path: ["passkey", "login", "begin"], method: "POST", authenticated: false)
  }

  public func listPasskeys() async throws -> PasskeyListResponse {
    try await http.request(path: ["passkeys"], authenticated: true)
  }

  public func renamePasskey(id: String, name: String) async throws -> MessageResponse {
    try await http.request(
      path: ["passkeys", id], method: "PUT", body: ["name": try .encoding(name)],
      authenticated: true)
  }

  public func deletePasskey(id: String) async throws -> MessageResponse {
    try await http.request(path: ["passkeys", id], method: "DELETE", authenticated: true)
  }

  public func listSessions() async throws -> SessionListResponse {
    try await http.request(path: ["sessions"], authenticated: true)
  }

  public func revokeSession(id: String) async throws -> MessageResponse {
    try await http.request(path: ["sessions", id], method: "DELETE", authenticated: true)
  }

  public func revokeOtherSessions() async throws -> MessageResponse {
    try await http.request(path: ["sessions"], method: "DELETE", authenticated: true)
  }

  public func getActivityLog(id: String) async throws -> ActivityLogResponse {
    try await http.request(path: ["activity-logs", id], authenticated: true)
  }

  public func getActivityEventTypes() async throws -> ActivityEventTypesResponse {
    try await http.request(path: ["activity-logs", "event-types"], authenticated: true)
  }

}
