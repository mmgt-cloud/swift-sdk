// Derived from platform DTO declarations. Verification status and hashes: Contracts/platform.json.
import Foundation
import MMGTCore

public struct ApiTokenResponse: Codable, Sendable, Equatable {
  public var accessToken: String?
  public var refreshToken: String?
  public var passwordExpired: Bool?
  public init(accessToken: String? = nil, refreshToken: String? = nil, passwordExpired: Bool? = nil)
  {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.passwordExpired = passwordExpired
  }
  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
    case passwordExpired = "password_expired"
  }
}

public struct MessageResponse: Codable, Sendable, Equatable {
  public var message: String
  public init(message: String) {
    self.message = message
  }
  enum CodingKeys: String, CodingKey {
    case message = "message"
  }
}

public struct ValidateTokenResponse: Codable, Sendable, Equatable {
  public var valid: Bool
  public var userID: String
  public var email: String
  public var appId: String
  public init(valid: Bool, userID: String, email: String, appId: String) {
    self.valid = valid
    self.userID = userID
    self.email = email
    self.appId = appId
  }
  enum CodingKeys: String, CodingKey {
    case valid = "valid"
    case userID = "userID"
    case email = "email"
    case appId = "app_id"
  }
}

public struct ErrorResponse: Codable, Sendable, Equatable {
  public var error: String
  public var retryAfter: Int?
  public var captchaRequired: Bool?
  public var siteKey: String?
  public var lockedUntil: String?
  public init(
    error: String, retryAfter: Int? = nil, captchaRequired: Bool? = nil, siteKey: String? = nil,
    lockedUntil: String? = nil
  ) {
    self.error = error
    self.retryAfter = retryAfter
    self.captchaRequired = captchaRequired
    self.siteKey = siteKey
    self.lockedUntil = lockedUntil
  }
  enum CodingKeys: String, CodingKey {
    case error = "error"
    case retryAfter = "retry_after"
    case captchaRequired = "captcha_required"
    case siteKey = "site_key"
    case lockedUntil = "locked_until"
  }
}

public struct RegisterRequest: Codable, Sendable, Equatable {
  public var email: String
  public var password: String
  public init(email: String, password: String) {
    self.email = email
    self.password = password
  }
  enum CodingKeys: String, CodingKey {
    case email = "email"
    case password = "password"
  }
}

public struct EmailCodeRequest: Codable, Sendable, Equatable {
  public var email: String
  public var code: String
  public init(email: String, code: String) {
    self.email = email
    self.code = code
  }
  enum CodingKeys: String, CodingKey {
    case email = "email"
    case code = "code"
  }
}

public struct LoginRequest: Codable, Sendable, Equatable {
  public var email: String
  public var password: String
  public var captchaToken: String?
  public init(email: String, password: String, captchaToken: String? = nil) {
    self.email = email
    self.password = password
    self.captchaToken = captchaToken
  }
  enum CodingKeys: String, CodingKey {
    case email = "email"
    case password = "password"
    case captchaToken = "captcha_token"
  }
}

public typealias TwoFAMethod = String

public struct TwoFALoginRequest: Codable, Sendable, Equatable {
  public var tempToken: String
  public var code: String?
  public var recoveryCode: String?
  public var rememberDevice: Bool?
  public var deviceName: String?
  public init(
    tempToken: String, code: String? = nil, recoveryCode: String? = nil,
    rememberDevice: Bool? = nil, deviceName: String? = nil
  ) {
    self.tempToken = tempToken
    self.code = code
    self.recoveryCode = recoveryCode
    self.rememberDevice = rememberDevice
    self.deviceName = deviceName
  }
  enum CodingKeys: String, CodingKey {
    case tempToken = "temp_token"
    case code = "code"
    case recoveryCode = "recovery_code"
    case rememberDevice = "remember_device"
    case deviceName = "device_name"
  }
}

public struct TwoFASetupResponse: Codable, Sendable, Equatable {
  public var secret: String
  public var qrCodeUrl: String
  public var qrCodeData: String?
  public init(secret: String, qrCodeUrl: String, qrCodeData: String? = nil) {
    self.secret = secret
    self.qrCodeUrl = qrCodeUrl
    self.qrCodeData = qrCodeData
  }
  enum CodingKeys: String, CodingKey {
    case secret = "secret"
    case qrCodeUrl = "qr_code_url"
    case qrCodeData = "qr_code_data"
  }
}

public struct TwoFAEnableResponse: Codable, Sendable, Equatable {
  public var message: String
  public var recoveryCodes: [String]
  public init(message: String, recoveryCodes: [String]) {
    self.message = message
    self.recoveryCodes = recoveryCodes
  }
  enum CodingKeys: String, CodingKey {
    case message = "message"
    case recoveryCodes = "recovery_codes"
  }
}

public struct TwoFARecoveryCodesResponse: Codable, Sendable, Equatable {
  public var message: String
  public var recoveryCodes: [String]
  public init(message: String, recoveryCodes: [String]) {
    self.message = message
    self.recoveryCodes = recoveryCodes
  }
  enum CodingKeys: String, CodingKey {
    case message = "message"
    case recoveryCodes = "recovery_codes"
  }
}

public struct TwoFAMethodsResponse: Codable, Sendable, Equatable {
  public var availableMethods: [String]
  public var email2faEnabled: Bool
  public var totpEnabled: Bool
  public var passkeyEnabled: Bool
  public var smsEnabled: Bool
  public init(
    availableMethods: [String], email2faEnabled: Bool, totpEnabled: Bool, passkeyEnabled: Bool,
    smsEnabled: Bool
  ) {
    self.availableMethods = availableMethods
    self.email2faEnabled = email2faEnabled
    self.totpEnabled = totpEnabled
    self.passkeyEnabled = passkeyEnabled
    self.smsEnabled = smsEnabled
  }
  enum CodingKeys: String, CodingKey {
    case availableMethods = "available_methods"
    case email2faEnabled = "email_2fa_enabled"
    case totpEnabled = "totp_enabled"
    case passkeyEnabled = "passkey_enabled"
    case smsEnabled = "sms_enabled"
  }
}

public struct AddBackupEmailRequest: Codable, Sendable, Equatable {
  public var backupEmail: String
  public init(backupEmail: String) {
    self.backupEmail = backupEmail
  }
  enum CodingKeys: String, CodingKey {
    case backupEmail = "backup_email"
  }
}

public struct BackupEmailStatusResponse: Codable, Sendable, Equatable {
  public var backupEmail: String?
  public var verified: Bool
  public var pendingEmail: String?
  public init(backupEmail: String? = nil, verified: Bool, pendingEmail: String? = nil) {
    self.backupEmail = backupEmail
    self.verified = verified
    self.pendingEmail = pendingEmail
  }
  enum CodingKeys: String, CodingKey {
    case backupEmail = "backup_email"
    case verified = "verified"
    case pendingEmail = "pending_email"
  }
}

public struct AddPhoneRequest: Codable, Sendable, Equatable {
  public var phoneNumber: String
  public init(phoneNumber: String) {
    self.phoneNumber = phoneNumber
  }
  enum CodingKeys: String, CodingKey {
    case phoneNumber = "phone_number"
  }
}

public struct VerifyPhoneRequest: Codable, Sendable, Equatable {
  public var code: String
  public init(code: String) {
    self.code = code
  }
  enum CodingKeys: String, CodingKey {
    case code = "code"
  }
}

public struct PhoneStatusResponse: Codable, Sendable, Equatable {
  public var phoneNumber: String?
  public var verified: Bool
  public init(phoneNumber: String? = nil, verified: Bool) {
    self.phoneNumber = phoneNumber
    self.verified = verified
  }
  enum CodingKeys: String, CodingKey {
    case phoneNumber = "phone_number"
    case verified = "verified"
  }
}

public struct TrustedDeviceResponse: Codable, Sendable, Equatable {
  public var id: String
  public var name: String
  public var userAgent: String?
  public var ipAddress: String?
  public var lastUsedAt: String
  public var expiresAt: String
  public var createdAt: String
  public init(
    id: String, name: String, userAgent: String? = nil, ipAddress: String? = nil,
    lastUsedAt: String, expiresAt: String, createdAt: String
  ) {
    self.id = id
    self.name = name
    self.userAgent = userAgent
    self.ipAddress = ipAddress
    self.lastUsedAt = lastUsedAt
    self.expiresAt = expiresAt
    self.createdAt = createdAt
  }
  enum CodingKeys: String, CodingKey {
    case id = "id"
    case name = "name"
    case userAgent = "user_agent"
    case ipAddress = "ip_address"
    case lastUsedAt = "last_used_at"
    case expiresAt = "expires_at"
    case createdAt = "created_at"
  }
}

public struct TrustedDevicesListResponse: Codable, Sendable, Equatable {
  public var devices: [TrustedDeviceResponse]
  public init(devices: [TrustedDeviceResponse]) {
    self.devices = devices
  }
  enum CodingKeys: String, CodingKey {
    case devices = "devices"
  }
}

public struct SocialAccountResponse: Codable, Sendable, Equatable {
  public var id: String
  public var provider: String
  public var providerUserId: String
  public var email: String?
  public var name: String?
  public var firstName: String?
  public var lastName: String?
  public var profilePicture: String?
  public var username: String?
  public var locale: String?
  public var createdAt: String
  public var updatedAt: String
  public init(
    id: String, provider: String, providerUserId: String, email: String? = nil, name: String? = nil,
    firstName: String? = nil, lastName: String? = nil, profilePicture: String? = nil,
    username: String? = nil, locale: String? = nil, createdAt: String, updatedAt: String
  ) {
    self.id = id
    self.provider = provider
    self.providerUserId = providerUserId
    self.email = email
    self.name = name
    self.firstName = firstName
    self.lastName = lastName
    self.profilePicture = profilePicture
    self.username = username
    self.locale = locale
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
  enum CodingKeys: String, CodingKey {
    case id = "id"
    case provider = "provider"
    case providerUserId = "provider_user_id"
    case email = "email"
    case name = "name"
    case firstName = "first_name"
    case lastName = "last_name"
    case profilePicture = "profile_picture"
    case username = "username"
    case locale = "locale"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }
}

public struct SocialAccountListResponse: Codable, Sendable, Equatable {
  public var socialAccounts: [SocialAccountResponse]
  public init(socialAccounts: [SocialAccountResponse]) {
    self.socialAccounts = socialAccounts
  }
  enum CodingKeys: String, CodingKey {
    case socialAccounts = "social_accounts"
  }
}

public struct UserResponse: Codable, Sendable, Equatable {
  public var id: String
  public var email: String
  public var emailVerified: Bool
  public var name: String?
  public var firstName: String?
  public var lastName: String?
  public var profilePicture: String?
  public var locale: String?
  public var twoFaEnabled: Bool
  public var twoFaMethod: String?
  public var hasPassword: Bool
  public var roles: [String]?
  public var createdAt: String
  public var updatedAt: String
  public var socialAccounts: [SocialAccountResponse]?
  public init(
    id: String, email: String, emailVerified: Bool, name: String? = nil, firstName: String? = nil,
    lastName: String? = nil, profilePicture: String? = nil, locale: String? = nil,
    twoFaEnabled: Bool, twoFaMethod: String? = nil, hasPassword: Bool, roles: [String]? = nil,
    createdAt: String, updatedAt: String, socialAccounts: [SocialAccountResponse]? = nil
  ) {
    self.id = id
    self.email = email
    self.emailVerified = emailVerified
    self.name = name
    self.firstName = firstName
    self.lastName = lastName
    self.profilePicture = profilePicture
    self.locale = locale
    self.twoFaEnabled = twoFaEnabled
    self.twoFaMethod = twoFaMethod
    self.hasPassword = hasPassword
    self.roles = roles
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.socialAccounts = socialAccounts
  }
  enum CodingKeys: String, CodingKey {
    case id = "id"
    case email = "email"
    case emailVerified = "email_verified"
    case name = "name"
    case firstName = "first_name"
    case lastName = "last_name"
    case profilePicture = "profile_picture"
    case locale = "locale"
    case twoFaEnabled = "two_fa_enabled"
    case twoFaMethod = "two_fa_method"
    case hasPassword = "has_password"
    case roles = "roles"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case socialAccounts = "social_accounts"
  }
}

public struct UpdateProfileRequest: Codable, Sendable, Equatable {
  public var name: String?
  public var firstName: String?
  public var lastName: String?
  public var profilePicture: String?
  public var locale: String?
  public init(
    name: String? = nil, firstName: String? = nil, lastName: String? = nil,
    profilePicture: String? = nil, locale: String? = nil
  ) {
    self.name = name
    self.firstName = firstName
    self.lastName = lastName
    self.profilePicture = profilePicture
    self.locale = locale
  }
  enum CodingKeys: String, CodingKey {
    case name = "name"
    case firstName = "first_name"
    case lastName = "last_name"
    case profilePicture = "profile_picture"
    case locale = "locale"
  }
}

public struct UpdateEmailRequest: Codable, Sendable, Equatable {
  public var email: String
  public var password: String
  public init(email: String, password: String) {
    self.email = email
    self.password = password
  }
  enum CodingKeys: String, CodingKey {
    case email = "email"
    case password = "password"
  }
}

public struct UpdatePasswordRequest: Codable, Sendable, Equatable {
  public var currentPassword: String
  public var newPassword: String
  public init(currentPassword: String, newPassword: String) {
    self.currentPassword = currentPassword
    self.newPassword = newPassword
  }
  enum CodingKeys: String, CodingKey {
    case currentPassword = "current_password"
    case newPassword = "new_password"
  }
}

public struct DeleteAccountRequest: Codable, Sendable, Equatable {
  public var password: String?
  public var confirmDeletion: Bool
  public init(password: String? = nil, confirmDeletion: Bool) {
    self.password = password
    self.confirmDeletion = confirmDeletion
  }
  enum CodingKeys: String, CodingKey {
    case password = "password"
    case confirmDeletion = "confirm_deletion"
  }
}

public struct SetPasswordRequest: Codable, Sendable, Equatable {
  public var newPassword: String
  public init(newPassword: String) {
    self.newPassword = newPassword
  }
  enum CodingKeys: String, CodingKey {
    case newPassword = "new_password"
  }
}

public struct ForgotPasswordRequest: Codable, Sendable, Equatable {
  public var email: String
  public init(email: String) {
    self.email = email
  }
  enum CodingKeys: String, CodingKey {
    case email = "email"
  }
}

public struct ResetPasswordRequest: Codable, Sendable, Equatable {
  public var token: String
  public var newPassword: String
  public init(token: String, newPassword: String) {
    self.token = token
    self.newPassword = newPassword
  }
  enum CodingKeys: String, CodingKey {
    case token = "token"
    case newPassword = "new_password"
  }
}

public struct ResendVerificationRequest: Codable, Sendable, Equatable {
  public var email: String
  public init(email: String) {
    self.email = email
  }
  enum CodingKeys: String, CodingKey {
    case email = "email"
  }
}

public struct MagicLinkRequest: Codable, Sendable, Equatable {
  public var email: String
  public init(email: String) {
    self.email = email
  }
  enum CodingKeys: String, CodingKey {
    case email = "email"
  }
}

public struct MagicLinkVerifyRequest: Codable, Sendable, Equatable {
  public var token: String
  public var appId: String?
  public init(token: String, appId: String? = nil) {
    self.token = token
    self.appId = appId
  }
  enum CodingKeys: String, CodingKey {
    case token = "token"
    case appId = "app_id"
  }
}

public struct MergeAccountRequest: Codable, Sendable, Equatable {
  public var mergeToken: String
  public var password: String
  public init(mergeToken: String, password: String) {
    self.mergeToken = mergeToken
    self.password = password
  }
  enum CodingKeys: String, CodingKey {
    case mergeToken = "merge_token"
    case password = "password"
  }
}

public struct AppLoginConfigResponse: Codable, Sendable, Equatable {
  public var appId: String
  public var enabledSocialProviders: [String]
  public var oidcEnabled: Bool
  public var hasOidcClients: Bool
  public var magicLinkEnabled: Bool
  public var emailCodeLoginEnabled: Bool
  public var passkeyLoginEnabled: Bool
  public var twoFaEnabled: Bool
  public var twoFaRequired: Bool
  public var sms2FAEnabled: Bool
  public var trustedDeviceEnabled: Bool
  public var loginLogoUrl: String?
  public var loginPrimaryColor: String?
  public var loginSecondaryColor: String?
  public var loginDisplayName: String?
  public var oidcClientLoginTheme: String?
  public var pwMinLength: Int
  public var pwMaxLength: Int
  public var pwRequireUpper: Bool
  public var pwRequireLower: Bool
  public var pwRequireDigit: Bool
  public var pwRequireSymbol: Bool
  public init(
    appId: String, enabledSocialProviders: [String], oidcEnabled: Bool, hasOidcClients: Bool,
    magicLinkEnabled: Bool, emailCodeLoginEnabled: Bool, passkeyLoginEnabled: Bool,
    twoFaEnabled: Bool, twoFaRequired: Bool, sms2FAEnabled: Bool, trustedDeviceEnabled: Bool,
    loginLogoUrl: String? = nil, loginPrimaryColor: String? = nil,
    loginSecondaryColor: String? = nil, loginDisplayName: String? = nil,
    oidcClientLoginTheme: String? = nil, pwMinLength: Int, pwMaxLength: Int, pwRequireUpper: Bool,
    pwRequireLower: Bool, pwRequireDigit: Bool, pwRequireSymbol: Bool
  ) {
    self.appId = appId
    self.enabledSocialProviders = enabledSocialProviders
    self.oidcEnabled = oidcEnabled
    self.hasOidcClients = hasOidcClients
    self.magicLinkEnabled = magicLinkEnabled
    self.emailCodeLoginEnabled = emailCodeLoginEnabled
    self.passkeyLoginEnabled = passkeyLoginEnabled
    self.twoFaEnabled = twoFaEnabled
    self.twoFaRequired = twoFaRequired
    self.sms2FAEnabled = sms2FAEnabled
    self.trustedDeviceEnabled = trustedDeviceEnabled
    self.loginLogoUrl = loginLogoUrl
    self.loginPrimaryColor = loginPrimaryColor
    self.loginSecondaryColor = loginSecondaryColor
    self.loginDisplayName = loginDisplayName
    self.oidcClientLoginTheme = oidcClientLoginTheme
    self.pwMinLength = pwMinLength
    self.pwMaxLength = pwMaxLength
    self.pwRequireUpper = pwRequireUpper
    self.pwRequireLower = pwRequireLower
    self.pwRequireDigit = pwRequireDigit
    self.pwRequireSymbol = pwRequireSymbol
  }
  enum CodingKeys: String, CodingKey {
    case appId = "app_id"
    case enabledSocialProviders = "enabled_social_providers"
    case oidcEnabled = "oidc_enabled"
    case hasOidcClients = "has_oidc_clients"
    case magicLinkEnabled = "magic_link_enabled"
    case emailCodeLoginEnabled = "email_code_login_enabled"
    case passkeyLoginEnabled = "passkey_login_enabled"
    case twoFaEnabled = "two_fa_enabled"
    case twoFaRequired = "two_fa_required"
    case sms2FAEnabled = "sms_2fa_enabled"
    case trustedDeviceEnabled = "trusted_device_enabled"
    case loginLogoUrl = "login_logo_url"
    case loginPrimaryColor = "login_primary_color"
    case loginSecondaryColor = "login_secondary_color"
    case loginDisplayName = "login_display_name"
    case oidcClientLoginTheme = "oidc_client_login_theme"
    case pwMinLength = "pw_min_length"
    case pwMaxLength = "pw_max_length"
    case pwRequireUpper = "pw_require_upper"
    case pwRequireLower = "pw_require_lower"
    case pwRequireDigit = "pw_require_digit"
    case pwRequireSymbol = "pw_require_symbol"
  }
}

public struct PasskeyResponse: Codable, Sendable, Equatable {
  public var id: String
  public var name: String
  public var createdAt: String
  public var lastUsedAt: String?
  public var backupEligible: Bool
  public var backupState: Bool
  public var transports: [String]
  public init(
    id: String, name: String, createdAt: String, lastUsedAt: String? = nil, backupEligible: Bool,
    backupState: Bool, transports: [String]
  ) {
    self.id = id
    self.name = name
    self.createdAt = createdAt
    self.lastUsedAt = lastUsedAt
    self.backupEligible = backupEligible
    self.backupState = backupState
    self.transports = transports
  }
  enum CodingKeys: String, CodingKey {
    case id = "id"
    case name = "name"
    case createdAt = "created_at"
    case lastUsedAt = "last_used_at"
    case backupEligible = "backup_eligible"
    case backupState = "backup_state"
    case transports = "transports"
  }
}

public struct PasskeyListResponse: Codable, Sendable, Equatable {
  public var passkeys: [PasskeyResponse]
  public init(passkeys: [PasskeyResponse]) {
    self.passkeys = passkeys
  }
  enum CodingKeys: String, CodingKey {
    case passkeys = "passkeys"
  }
}

public struct PasskeyLoginBeginResponse: Codable, Sendable, Equatable {
  public var options: JSONValue
  public var sessionId: String
  public init(options: JSONValue, sessionId: String) {
    self.options = options
    self.sessionId = sessionId
  }
  enum CodingKeys: String, CodingKey {
    case options = "options"
    case sessionId = "session_id"
  }
}

public struct SessionResponse: Codable, Sendable, Equatable {
  public var id: String
  public var ipAddress: String
  public var userAgent: String
  public var createdAt: String
  public var lastActive: String
  public var isCurrent: Bool
  public init(
    id: String, ipAddress: String, userAgent: String, createdAt: String, lastActive: String,
    isCurrent: Bool
  ) {
    self.id = id
    self.ipAddress = ipAddress
    self.userAgent = userAgent
    self.createdAt = createdAt
    self.lastActive = lastActive
    self.isCurrent = isCurrent
  }
  enum CodingKeys: String, CodingKey {
    case id = "id"
    case ipAddress = "ip_address"
    case userAgent = "user_agent"
    case createdAt = "created_at"
    case lastActive = "last_active"
    case isCurrent = "is_current"
  }
}

public struct SessionListResponse: Codable, Sendable, Equatable {
  public var sessions: [SessionResponse]
  public init(sessions: [SessionResponse]) {
    self.sessions = sessions
  }
  enum CodingKeys: String, CodingKey {
    case sessions = "sessions"
  }
}

public struct ActivityLogResponse: Codable, Sendable, Equatable {
  public var id: String
  public var userId: String
  public var eventType: String
  public var timestamp: String
  public var ipAddress: String
  public var userAgent: String
  public var details: JSONValue
  public var isAnomaly: Bool
  public var severity: String
  public init(
    id: String, userId: String, eventType: String, timestamp: String, ipAddress: String,
    userAgent: String, details: JSONValue, isAnomaly: Bool, severity: String
  ) {
    self.id = id
    self.userId = userId
    self.eventType = eventType
    self.timestamp = timestamp
    self.ipAddress = ipAddress
    self.userAgent = userAgent
    self.details = details
    self.isAnomaly = isAnomaly
    self.severity = severity
  }
  enum CodingKeys: String, CodingKey {
    case id = "id"
    case userId = "user_id"
    case eventType = "event_type"
    case timestamp = "timestamp"
    case ipAddress = "ip_address"
    case userAgent = "user_agent"
    case details = "details"
    case isAnomaly = "is_anomaly"
    case severity = "severity"
  }
}

public struct PaginationResponse: Codable, Sendable, Equatable {
  public var page: Int
  public var limit: Int
  public var totalRecords: Int
  public var totalPages: Int
  public var hasNext: Bool
  public var hasPrevious: Bool
  public init(
    page: Int, limit: Int, totalRecords: Int, totalPages: Int, hasNext: Bool, hasPrevious: Bool
  ) {
    self.page = page
    self.limit = limit
    self.totalRecords = totalRecords
    self.totalPages = totalPages
    self.hasNext = hasNext
    self.hasPrevious = hasPrevious
  }
  enum CodingKeys: String, CodingKey {
    case page = "page"
    case limit = "limit"
    case totalRecords = "total_records"
    case totalPages = "total_pages"
    case hasNext = "has_next"
    case hasPrevious = "has_previous"
  }
}

public struct ActivityLogListResponse: Codable, Sendable, Equatable {
  public var data: [ActivityLogResponse]
  public var pagination: PaginationResponse
  public init(data: [ActivityLogResponse], pagination: PaginationResponse) {
    self.data = data
    self.pagination = pagination
  }
  enum CodingKeys: String, CodingKey {
    case data = "data"
    case pagination = "pagination"
  }
}

public struct ActivityLogExportResponse: Codable, Sendable, Equatable {
  public var data: [ActivityLogResponse]
  public var count: Int
  public var truncated: Bool
  public var exportedAt: String
  public init(data: [ActivityLogResponse], count: Int, truncated: Bool, exportedAt: String) {
    self.data = data
    self.count = count
    self.truncated = truncated
    self.exportedAt = exportedAt
  }
  enum CodingKeys: String, CodingKey {
    case data = "data"
    case count = "count"
    case truncated = "truncated"
    case exportedAt = "exported_at"
  }
}

public struct ActivityEventTypesResponse: Codable, Sendable, Equatable {
  public var eventTypes: [String]
  public init(eventTypes: [String]) {
    self.eventTypes = eventTypes
  }
  enum CodingKeys: String, CodingKey {
    case eventTypes = "event_types"
  }
}
