# Changelog

## Unreleased

- Fence delayed overlapping Sync pulls and snapshots using durable per-scope
  snapshot watermarks, including authoritative absence. Upgrade SQLite v1 by
  rebuilding feeds while preserving pending mutations and issues for review.
  Add workspace-aware `bootstrap(scope:)`, migration/fault tests and HTTP DTO tests.

- Correct AI tool continuation to send `tool_result` frames after a single
  `start`; count tool rounds independently of the final generation. Validate
  complete call lists before effects, retain per-run deduplication and reject
  late results after cancellation/account changes. Add HTTP/file and shared
  wire-contract tests. The corresponding server state correction requires rollout.


- Correct live-test Realtime grant preflight for the server's two-part signed
  wire format, with seven deterministic scope/encoding/expiry regressions.
  Report the failing Realtime phase and safe HTTP/network codes in device tests.

- Wait for the originating scene to become active before OIDC or account-provider
  browser presentation after a system credential sheet. Bound the wait to ten
  seconds, honor cancellation and reject detached windows. Fence delayed OIDC
  cancellation to its own attempt so it cannot cancel a newer login.

- Accept both canonical `/oidc/<app>` discovery endpoints and the `/auth/oidc/<app>`
  alias on the configured origin. Preserve the issuer and reject other hosts,
  applications, ports, query strings and credentials in endpoint URLs.

- Add a separate signed-iPhone passkey and HTTPS OIDC acceptance target with
  explicit Associated Domains, artifact checks and durable no-retry test intent.

- Add opt-in account-bound trusted-device transport for password/MFA login,
  secure Keychain persistence and explicit forget. Plain transports reject
  `rememberDevice: true` instead of silently discarding the server cookie.
- Eight Swift Package Manager products for iOS 26+, Swift tools 6.2 and Swift 6.
- Auth session ownership, durable Keychain activation, system-browser OIDC and
  provider-account flows, native passkeys and explicit MFA/account operations.
- Token providers are obtained with `await session.tokenProvider` after login and
  are bound to that session generation. Retained clients cannot adopt another
  account. Incomplete MFA and OpenID token results fail explicitly.
- Billing user API, Realtime WebSocket feeds, presence and confirmed cursors,
  Sync with atomic SQLite outbox/snapshot recovery, and AI HTTP/WebSocket/tools.
- Observable service state and foreground lifecycle integration without packaged UI.
- SwiftUI example, synthetic cross-language fixtures, DocC, privacy manifests and
  local simulator, compiler, documentation and application-hosted device runners.

No tag or stable release is published. Native Auth needs the corresponding
platform migration and environment/device acceptance. Existing experimental
Keychain entries without an activation fence require sign-in again. Token exchange
and account-operation failures must follow the documented reconciliation rules.
