# Changelog

## Unreleased

- Eight Swift Package Manager products for iOS 26+, Swift tools 6.2 and Swift 6.
- Auth session ownership, durable Keychain activation, system-browser OIDC and
  provider-account flows, native passkeys and explicit MFA/account operations.
- Billing user API, Realtime WebSocket feeds, presence and confirmed cursors,
  Sync with atomic SQLite outbox/snapshot recovery, and AI HTTP/WebSocket/tools.
- Observable service state and foreground lifecycle integration without packaged UI.
- SwiftUI example, synthetic cross-language fixtures, DocC, privacy manifests and
  local simulator, compiler, documentation and application-hosted device runners.

No tag or stable release is published. Native Auth needs the corresponding
platform migration and environment/device acceptance. Existing experimental
Keychain entries without an activation fence require sign-in again. Token exchange
and account-operation failures must follow the documented reconciliation rules.
