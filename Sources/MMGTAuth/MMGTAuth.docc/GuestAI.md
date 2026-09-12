# Technical guest sessions

Development candidate: GuestSession is implemented, with local iOS 27 checks.
Physical-device and stage/prod acceptance and publication remain pending.

A local guest profile is application data. It starts offline and is independent
of the technical session used to call AI. ``GuestSession`` never creates an
ordinary Auth user, membership or role. It cannot open Sync, Billing or Realtime.
Create it with the application's Auth configuration and a saved local profile ID.
Construction and `summary()` make no HTTP request. Obtain its `tokenProvider` for
AIClient; the first explicit online use persists a renewal credential in Keychain
before asking Auth for access.

The default ``KeychainGuestSessionStore`` partitions by service environment, app
and local profile. It disables synchronizable credentials and uses
`WhenUnlockedThisDeviceOnly`. It conditionally updates the saved revision and
credential together, using [Security's matching update](https://developer.apple.com/documentation/security/secitemupdate(_:_:))
and the generic-password [application-defined attribute](https://developer.apple.com/documentation/security/ksecattrgeneric).
Real Keychain CAS is tested in an application host with the required access-group
identity; an unsigned SPM test process does not supply that identity. A locked or
unavailable Keychain fails before a network request or cached-token return.
The explicitly volatile ``MemoryGuestSessionStore`` is useful for tests; custom
stores must provide atomic CAS across all owners sharing their data.

Access credentials are opaque and last at most five minutes. Renewing retains
the guest ID and counters. Thirty days of server-side inactivity expires the
technical session. Concurrent requests on one owner share a renewal; another
owner cannot overwrite a revocation marker. Lost create/renew responses recover
through the same stored renewal credential. This recovery never retries a model
generation or tool execution.

Guest AI is disabled until the app owner enables exact connection/model pairs
with positive limits in Panel. Handle `APIError.code` and ``GuestSessionError``
for disabled policy, expired/revoked sessions, quota, unavailable authorization
and invalid responses. There is no automatic identity reset, fallback or retry
after these errors. Guest or application invocation/time limits are not guaranteed
provider token or monetary budgets.

`revoke()` persists its terminal intent before calling Auth. A lost response leaves
a revoking marker; call revoke again to resume. `startNewSession()` is an explicit
action after expiry or completed revocation. Acquire a new token provider and
recreate the AI client for that new technical identity. `close()` fences delayed
responses through the old instance and preserves its partition. Close its AI
stream and bind tool callbacks to the originating local profile on account change.

AI requires internet. Prompts, selected context, tool outputs and temporary files
are transmitted to the configured provider, including while Sync is disabled.
The developer owns tool validation, confirmations, domain writes and chat history.
AI upload IDs expire after one hour and must not become permanent domain-media
references. Domain synchronization and guest-to-account import are separate
LocalReplica operations.
