# ``MMGTAuth``

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

`KeychainSessionStore` separates application/environment sessions and records the active account. Entries are not synchronized through iCloud and use WhenUnlockedThisDeviceOnly accessibility. A local activation fence is invalidated before token deletion and is excluded from backup. If Keychain deletion fails, a restarted app cannot restore those credentials; the deletion error remains visible and cleanup must be retried after protected data becomes available. A failed fence write also fails logout and requires explicit recovery. Legacy development entries without a matching fence require sign-in again. The fence contains only a random generation and an activation flag, never credentials.

Logout closes attached account clients and rejects late profile/refresh responses. Pending Sync mutations stay under their old account identity. Recreate clients and observable state after an account change.

Use `AuthSession.performAccountOperation` for account changes and queries: it binds
the token to that session, cancels work on logout and rejects late results.
`NativeAccountAuthorizer` uses this boundary for linking Google, Apple, Facebook
and GitHub accounts. Provider reauthentication follows the existing Google/Apple
contract; password and passkey reauthentication remain available independently.
The registered native callback receives an opaque code and state. PKCE and the
current session are required to finish; no provider credential reaches the app.
Approval changes, session deletion or required MFA enrollment reject a pending
operation. Never automatically replay a failed finish: reconcile linked accounts
from the server after a lost response, or begin fresh reauthentication.

TOTP setup requires `generate2FA`, `verify2FASetup` and `enable2FA` in that order.
Verification belongs to the exact generated secret and activation is single-use.
A storage failure during activation requires a new setup. Always present recovery
codes privately and let the user store them before dismissing setup.

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
### Native authentication
- ``NativeOIDCConfiguration``
- ``OIDCAuthorizer``
- ``NativePasskeys``
- ``NativeAccountAuthorizer``
- ``NativeAccountProvider``
- ``ReauthenticationProof``
