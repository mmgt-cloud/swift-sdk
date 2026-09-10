# ``MMGTAuth``

Public entry operations are scoped to the configured application. Registration
returns a message, not a session. Email-code and magic-link verification can
require MFA or enrollment just like password login. Inspect `LoginResult` before
passing complete tokens to `AuthSession`; never treat temporary/enrollment tokens
or empty token strings as a completed sign-in. A password-expired result requires
the password reset flow. One-time codes and tokens must not be blindly retried
after an uncertain response.

`APIError.body` retains Auth's CAPTCHA and lockout fields (`captcha_required`,
`site_key`, `locked_until`, `retry_after`). These legacy endpoints may return
a message instead of a stable error code. Handle their HTTP status and typed
body; the SDK does not solve CAPTCHA, deliver mail or retry requests automatically.

Create `await session.tokenProvider` after successful authentication. It remains
valid through refresh and becomes permanently invalid after logout or another
authentication attempt. Create fresh service clients and token providers for the
new account. Attach lifecycle participants to cancel their outstanding work;
retaining an old provider never grants access as the next account.

Application user authentication and native authorization.

Own one `AuthSession` for an application/environment. Its token provider is the sole refresh owner shared by your service clients. `AuthState` observes session snapshots without importing SwiftUI.

Call `authenticate` with an `AuthClient` operation. A successful result is confirmed by the server's profile endpoint before the session is persisted. MFA challenges remain explicit results. Complete the selected MFA method and pass that operation through the same session owner.

Required enrollment is also an explicit result. Its restricted credentials last ten minutes, cannot refresh or access other services, and are not saved by `AuthSession`. Use the returned access token only in a separate `AuthClient` for MFA setup, then sign in again and verify the new factor. The hosted native authorization flow performs those steps within the browser before returning the code.

`OIDCAuthorizer` uses the system authentication browser and AppAuth for authorization/code exchange with PKCE, state and nonce. Register a public client without a client secret. HTTPS callbacks require the matching Associated Domain, signed application identity and operator-approved AASA. A custom scheme requires an explicitly registered development callback. `NativePasskeys` supports registration, passwordless sign-in, MFA, reauthentication and `enableTwoFactor` after a registered credential is verified. Keep recovery codes for the user; do not log them. It uses AuthenticationServices and the existing RP ID; never change the RP ID to migrate existing passkeys.

Pass a visible window belonging to the scene that initiates authorization. After
Face ID or another system sheet, credential completion can precede the scene's
return to foreground activity. Both browser authorizers wait up to ten seconds
for that same scene to become active before starting the browser. Cancellation,
a detached window or the timeout stops presentation; it does not retry login,
code exchange or an account operation. Keep the app in the foreground for these
interactive flows.

`KeychainSessionStore` separates application/environment sessions and records the active account. Entries are not synchronized through iCloud and use WhenUnlockedThisDeviceOnly accessibility. A local activation fence is invalidated before token deletion and is excluded from backup. If Keychain deletion fails, a restarted app cannot restore those credentials; the deletion error remains visible and cleanup must be retried after protected data becomes available. A failed fence write also fails logout and requires explicit recovery. Legacy development entries without a matching fence require sign-in again. The fence contains only a random generation and an activation flag, never credentials.

Logout closes attached account clients and rejects late profile/refresh responses. Pending Sync mutations stay under their old account identity. Recreate clients and observable state after an account change.

Use `AuthSession.performAccountOperation` for account changes and queries: it binds
the token to that session, cancels work on logout and rejects late results.
`NativeAccountAuthorizer` uses this boundary for linking Google, Apple, Facebook
and GitHub accounts. Provider reauthentication follows the existing Google/Apple
contract; password and passkey reauthentication remain available independently.
Callback validation errors identify only the failed structural check; they never
include the URL, state or code. Treat a rejected callback as a failed attempt.

The registered native callback receives an opaque code and state. PKCE and the
current session are required to finish; no provider credential reaches the app.
Approval changes, session deletion or required MFA enrollment reject a pending
operation. Never automatically replay a failed finish: reconcile linked accounts
from the server after a lost response, or begin fresh reauthentication.

TOTP setup requires `generate2FA`, `verify2FASetup` and `enable2FA` in that order.
Verification belongs to the exact generated secret and activation is single-use.
A storage failure during activation requires a new setup. Always present recovery
codes privately and let the user store them before dismissing setup.

Authentication does not grant every account permission. The application's roles
must permit the operation: profile reads use `user:read`, profile/password changes
use `user:write`, activity reads use `log:read`, and MFA management uses the
corresponding `settings` permission. `deleteAccount` requires `user:delete` in
addition to the password and explicit confirmation. The default `member` role
does not include deletion. Surface a 403 as a policy decision; do not repeatedly
reauthenticate or retry it. Role configuration belongs to the application's
backend/operator and cannot be changed with a user-only iOS client.

### Remembering a device

Password/MFA device trust is opt-in. Create a `TrustedDeviceTransport` with the
Auth configuration and account email, and pass it as the `transport` of the
`AuthSession`. Use that same transport for password login and verification of its
MFA challenge. Only set `TwoFALoginRequest.rememberDevice` after the user chooses
to remember the device. A plain transport rejects this option before sending,
instead of silently discarding the server's cookie.

The adapter accepts a secure, HttpOnly credential only after successful MFA and
sends it only to password login for that account, app and Auth environment.
Keychain entries use WhenUnlockedThisDeviceOnly, no iCloud synchronization, and a
backup-excluded activation fence. It never enables a shared cookie jar. Create a
new session and adapter when changing accounts; an adapter rejects another email.
`isRemembered()` describes unexpired local state, not server authorization: app
configuration, expiry or server revocation can still require MFA. If the server
does not issue a cookie, login may succeed with `isRemembered()` remaining false.

Remembered trust survives normal logout by design. Use `forget()` to delete it
locally, and the authenticated trusted-device endpoints to revoke it on the
server. Revoking all devices through the adapter also forgets local trust. A
single-device revocation invalidates server access immediately; the local token
can remain until explicitly forgotten or expired. Forget invalidates late MFA
responses before attempting Keychain deletion. A Keychain failure is visible and
must be retried when protected data becomes available; no request is retried
automatically. Canceling the MFA task also prevents a late response being saved.

Native browser authorization uses the system browser's own cookie context. It
does not import or export this password-login credential. Email OTP and passkey
sign-in retain their server MFA contracts; the adapter does not reinterpret them
as password login or claim device trust was applied.

<!-- compiled-quickstart -->
## Compiled quickstart

```swift
import MMGTAuth

func signInWithPassword(session: AuthSession, email: String, password: String) async throws
  -> LoginResult
{
  try await session.authenticate { client in
    try await client.login(input: .init(email: email, password: password))
  }
}
```
<!-- end-compiled-quickstart -->

## Topics
### User operations
- ``AuthClient``
- ``LoginResult``
### Session ownership
- ``AuthSession``
- ``AuthSessionSnapshot``
- ``AuthState``
- ``KeychainSessionStore``
- ``TrustedDeviceTransport``
### Native authentication
- ``NativeOIDCConfiguration``
- ``OIDCAuthorizer``
- ``NativePasskeys``
- ``NativeAccountAuthorizer``
- ``NativeAccountProvider``
- ``ReauthenticationProof``

## Profile facts and activity exports

`UserResponse.pendingEmail` is a requested address awaiting confirmation. Continue
to use `email` as the current account address until the server confirms the change.
Linked providers expose `emailVerified` and `emailIsPrivateRelay`; absent values
remain `nil`, not proof of either verified or unverified status. These properties
are server observations and do not grant application permissions.

Profile and provider reads require `user:read`, profile changes `user:write`, and
activity operations `log:read`. Session listing still requires an authenticated
session. The SDK does not refresh or retry a rejected profile change automatically.
Activity exports are capped at 10,000 rows. Prefer `exportActivityLogs` when you
need its `truncated` metadata; `exportActivityCSV` returns UTF-8 decoded CSV text
without response headers; Foundation consumes a leading UTF-8 BOM. Filters use `YYYY-MM-DD` dates.

## MFA method and recovery contracts

`get2FAMethods()` reads the application's effective policy without a user token.
The method list and convenience flags describe application availability, not the
current user's enrollment or proof that an SMS/e-mail provider delivered a code.
Protected security settings require the authenticated user's settings permissions;
login-code resend uses only its temporary login token. Backup-e-mail verification
uses its separate verification token. An unverified address or phone remains
unverified after decoding.

TOTP setup returns a secret, an `otpauth` URL and optional standard-base64 QR
bytes. Keep setup data and recovery codes private. Enabling a method and generating
replacement recovery codes are explicit writes without automatic retry. The
current recovery-code regeneration endpoint requires a TOTP code; it is not a
generic challenge for every MFA method. Check server state after an uncertain
response before initiating another account-security operation.

## Account changes and passkey endpoint contracts

`getAppConfig` reads only this client's application. Configuration flags describe
application settings, not successful mail/SMS delivery or a user's enrollment.
`updateEmail` starts confirmation at the new address; the old address remains
active until that confirmation. Prefer the reauthentication-proof flow for
accounts using providers or passkeys. Confirming an email change or changing a
password invalidates server sessions: clear local state and sign in again.
`setPassword` adds the first password to an account without one and returns a
conflict if one already exists.

Deletion requires explicit confirmation and the application's `user:delete`
permission. Password accounts supply their current password; social-only
accounts can omit it. `revokeSession` cannot revoke the current session; use
logout for that session. `revokeOtherSessions` keeps the current session.

Passkey registration, MFA enrollment and authentication are separate ceremonies.
Begin responses contain an `options.publicKey` envelope; passwordless login also
returns a `session_id` to supply unchanged to finish. Management IDs are server
credential UUIDs, distinct from the binary WebAuthn credential ID. Registering a
credential does not by itself enable MFA. Raw finish operations can return
restricted enrollment instead of a full session. No mutation is automatically
retried, including when the server may have accepted it before connectivity failed.

Password-only `confirmMerge` cannot bypass required or enrolled MFA. Complete
the existing account's authentication and use the authenticated linking flow
when instructed by the server. Native provider login uses the hosted OIDC flow
for this account reconciliation.

A passkey cancellation belongs to one ceremony. A queued cancellation or delegate
callback from a completed ceremony cannot finish or cancel its replacement. The
native helpers preserve server challenges, RP identity, credential bytes and
user-verification requirements. Their local request tests do not prove device
association: test the signed app, system prompts and callback on a real device.
