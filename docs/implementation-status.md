# Implementation and acceptance

Development started on 2026-09-09. This file reports work in progress, not a
release or a statement of environment readiness.

| Area | Implementation | Local verification | Stage | Production |
| --- | --- | --- | --- | --- |
| Core transport and wire values | Implemented; further hardening in progress | Initial simulator tests passed | Pending | Pending |
| Auth HTTP, session and Keychain | Implemented; native OIDC/passkeys pending | Logout/refresh response fencing tests passed | Pending | Pending |
| Billing | User endpoint client implemented | DTO checks passed; endpoint matrix pending | Pending | Pending |
| Realtime | Initial implementation complete | Ready deadline, identity, ACK/dedupe and cursor CAS tests passed | Pending | Pending |
| Sync and SQLite | Initial implementation complete | Six store/recovery tests passed | Pending | Pending |
| AI | Initial implementation complete | Sticky tool loop and interrupted-stream tests passed | Pending | Pending |
| SwiftUI | Lifecycle adapter implemented; state integration pending | Simulator build passed | Pending | Pending |
| Example application and DocC | Pending | Pending | Pending | Pending |
| Platform native Auth and ZIP | In progress in platform repository | OIDC code-consumption and public-client PostgreSQL/race tests passed | Pending | Pending |

Local evidence so far: Xcode 26.6 / Swift 6.3.3; 19 Swift tests on iOS Simulator.
Minimum compiler/runtime, physical-device, public-package installation and
full environment checks have not yet passed. No stable tag is available.

Remaining release gates include complete user-operation coverage, deterministic
WebSocket failures/cancellation, native OIDC/MFA/provider continuity, passkeys
and AASA, Panel configuration, ZIP examples, a sample iOS app, and local
stage-to-production acceptance. All limitations must be resolved or explicitly
reported before a stable release.
