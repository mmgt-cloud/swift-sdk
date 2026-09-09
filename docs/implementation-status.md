# Implementation and acceptance

Checkpoint: 2026-09-09 22:48 UTC. Development evidence, not a release or a
statement of stage/production readiness. No version tag is available.

| Area | Implementation | Local verification | Stage | Production |
| --- | --- | --- | --- | --- |
| Eight package products | Implemented; operation review continues | All products compile with Swift 6.2 for arm64/x86_64 Simulator | Full acceptance pending | Pending |
| Auth and native adapters | Session, Keychain, OIDC, passkeys, account operations and provider browser flow | Session races, persistence failures, restricted MFA and callback proofs pass; discovery correction under verification | iPhone passkey registration/sign-in/reauthentication passed; full native attempt failed at discovery | Pending |
| Billing | User endpoint client | Shared catalog/access/checkout DTO and request checks; full operation acceptance pending | Pending | Pending |
| Realtime | WebSocket, deadlines, reconnect, ACK/cursors and deduplication | First-frame auth, foreign-user rejection, bounded ready wait and cursor CAS pass; full fault matrix pending | Pending | Pending |
| Sync and SQLite | Durable outbox, scoped feeds, snapshot staging and conflicts | Restart/isolation, two writers, partial settlement and atomic recovery pass | Pending | Pending |
| AI | HTTP, WebSocket, tools, files and cancellation | Shared fixtures, one-socket tool loop, no duplicate execution and interrupted output pass | Swift fixture needs its own Codex connection | Pending |
| SwiftUI and example | Observable state, lifecycle, five service tabs and account actions | Example and eight byte-checked DocC quickstarts build with Swift 6.2 | Pending | Pending |
| Privacy | Eight SDK manifests and app integration guidance | Actual app contains SDK, AppAuth/AppAuthCore and GRDB manifests | App disclosures require review | App disclosures require review |
| DocC | Eight catalogs and local generator | Eight archives generated with warnings treated as errors | Not applicable | Public hosting pending |
| Platform native Auth, Panel and ZIP | Implemented in the private platform repository | Complete 14-group gate passed at platform 9268171 | Two migrations/four rollouts, actual Panel configuration/AASA and downloaded ZIP checks passed; full native gate open | Pending |

## Exact local evidence

At SDK `d25c7a4`, all 52 tests passed on official iOS 26.0 (23A343), with zero
skips, at 22:14 UTC. Report: `.artifacts/tests-20260909T221409Z/report.json`.
An earlier run at the same revision timed out in two MainActor tests. Both the
isolated five-test retry and the complete 52-test retry passed. The original
failure is retained and its cause remains unconfirmed.

All 52 synthetic tests also passed on the signed physical iPhone 16 Pro running
iOS 27.0 (24A5430a), using Xcode 27 beta, at 22:27 UTC, with zero skipped tests.
Report: `.artifacts/device-20260909T222657Z/report.json`. This synthetic result
does not establish live native authentication.

All eight products and compiled quickstarts passed with the official Swift 6.2
toolchain on both simulator architectures at `d25c7a4`. Eight DocC archives were
generated with warnings as errors. Reports: `.artifacts/compiler-20260909T223125Z`
and `.artifacts/docs-20260909T223433Z`. The compiler uses the iOS 26.5 SDK in
Xcode 26.6; minimum-compiler source builds and minimum-runtime execution are
separate evidence. Earlier runtime notes incorrectly called iOS 26.3.1 “26.5”.

The anonymous public consumer at `d25c7a4` built all eight products and an
Auth-only app without linking GRDB/SQLite. Report:
`.artifacts/public-install-3bf41bf007aa45b8a6584e8fcfa40cf3/report.json`.
This proves revision installation, not a versioned release or hosted DocC.

Five server DTO suites, five TypeScript client suites (84 tests), and six Swift
shared-fixture tests use the same 11 synthetic JSON files. Entries in
`Contracts/platform.json` without operation verification remain open.

## First actual native attempt and discovery correction

The signed physical iPhone at `d25c7a4` completed passkey registration, native
sign-in and passkey reauthentication against stage. It then stopped before
opening the system browser because SDK discovery validation rejected canonical
`/oidc/<app>/authorize` and `/oidc/<app>/token` paths. The deployed server
intentionally exposes those routes and `/auth/oidc` aliases. Public canonical
discovery and an actual PKCE authorization request both returned 200; the latter
rendered the native login page. This is an SDK validation defect, not a missing
server route. The issuer must remain unchanged.

The corrective test reproduces the failure with the canonical document. Endpoint
validation now accepts exactly the two supported path families on the configured
origin and application. Negative cases retain foreign host/app/path, port,
embedded credentials, query and fragment checks. New SDK tests, a new candidate
and fresh device/environment acceptance are still required. The failed run and
its one owned server credential remain recorded for cleanup; its run ID is not
reused. Private evidence: `.artifacts/native-run-9cc637db5e3f4de1b36e262619db7ef9`.

The separate `MMGTNative` target checks signed Associated Domains and build
hashes, records intent before starting, and requires stage before production.
It does not replace MFA, provider/account-lifecycle or five-service tests.

## Platform and service acceptance

The preceding full platform remediation completed both final gates at 21:43 UTC,
including recovery, rotation, backups, retention, cleanup and 30-minute
observation. Native platform `9268171` subsequently deployed to stage at 22:25 UTC.
Production still runs the accepted preceding release.

The complete local platform gate passed required Go integrations/race/vet, TS,
builds, 123 browser tests, audits, documentation and HA. Migration evidence now
matches exact selected Job identities, and the Swift bridge rejects a different
SDK commit before fixture/provider work.

Stage passed actual owner/step-up/operator-MFA configuration changes, denial of
tenant self-approval, stale-revision rejection, removal of AASA trust after an
update and explicit reapproval. Both actual Panel ZIP variants passed integrity,
YAML, secret-boundary and anonymous npm example checks. Domain APIs, three browser
engines, Sync grants/snapshots, outbox/projection, Stripe TEST webhook replay and
Codex HTTP/WebSocket on the existing Demo connection passed. These partial checks
do not constitute the complete native stage gate.

The five-service Swift suite compiles, but its fixture preparation stopped before
any generation because the newly provisioned application has no AI connection.
Existing Codex connections belong to Demo. Provisioning an AI resource does not
share another application's credentials; the disposable app needs a separate
connection through the existing account. No purchase or replacement account is
required by the test design. Availability and provider acceptance remain gates.

Trusted-device support is opt-in and account/app/environment bound. Its
Keychain activation fence rejects late MFA replies after forget/cancellation.
Plain transports reject `rememberDevice: true`. The server validates current
application policy; public trusted-device acceptance remains separate.

Auth npm client 1.1.0 and React 1.0.1 are published and anonymously verified.
Swift has its own version and acceptance process. Remaining work includes the
operation/fault matrix, corrected native and five-service device tests, complete
stage then production acceptance, actual iOS ZIP verification, immutable release,
Swift Package Index/hosted DocC and anonymous tagged installation.
