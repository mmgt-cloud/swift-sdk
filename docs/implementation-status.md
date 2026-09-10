# Implementation and acceptance

Checkpoint: 2026-09-10 08:12 UTC. Development evidence, not a release or a
statement of stage/production readiness. No version tag is available.

| Area | Implementation | Local verification | Stage | Production |
| --- | --- | --- | --- | --- |
| Eight package products | Implemented; operation review continues | All products compile with Swift 6.2 for arm64/x86_64 Simulator | Full acceptance pending | Pending |
| Auth and native adapters | Session, Keychain, OIDC, passkeys, account operations and provider browser flow | Discovery, bounded scene readiness and cancellation tests pass | Full passkey → system-browser HTTPS callback passes at 880c682; other native scenarios and new-candidate gates remain required | Pending |
| Billing | User endpoint client | All 18 HTTP operation contracts reviewed against server, six additional nonempty DTO fixtures and no-retry checkout failure cases pass | User reads pass; actual checkout/workspace acceptance pending | Pending |
| Realtime | WebSocket, deadlines, reconnect, ACK/cursors and deduplication | First-frame auth, foreign-user rejection, bounded ready wait and cursor CAS pass; full fault matrix pending | Native publish/event/ACK passes on physical iPhone after platform missing-Origin opt-in | Pending |
| Sync and SQLite | Durable outbox, scoped feeds, snapshot staging and conflicts | Restart/isolation, two writers, partial settlement and atomic recovery pass | Write, CAS conflict and snapshot pass in physical diagnostic; full gate pending | Pending |
| AI | HTTP, WebSocket, tools, files and cancellation | Shared fixtures, one-socket tool loop, no duplicate execution and interrupted output pass | Explicit Codex HTTP and WebSocket requests pass on physical iPhone; full file/tool fault matrix remains separate | Pending |
| SwiftUI and example | Observable state, lifecycle, five service tabs and account actions | Example and eight byte-checked DocC quickstarts build with Swift 6.2 | Pending | Pending |
| Privacy | Eight SDK manifests and app integration guidance | Actual app contains SDK, AppAuth/AppAuthCore and GRDB manifests | App disclosures require review | App disclosures require review |
| DocC | Eight catalogs and local generator | Eight archives generated with warnings treated as errors | Not applicable | Public hosting pending |
| Platform native Auth, Panel and ZIP | Implemented in the private platform repository | Complete 14-group gate passed at platform 9268171 | Two migrations/four rollouts, actual Panel configuration/AASA and downloaded ZIP checks passed; full native gate open | Pending |

## Current five-service and contract evidence

Exact SDK `ab0dc0735b8846078aecf1d736d159c1196babac` passed the complete
five-service scenario on the signed physical iPhone at 02:21:55 UTC on stage:
Auth, Sync CAS/snapshot, Realtime publish/event/ACK, Billing reads and explicit
Codex HTTP/WebSocket. The report is
`.artifacts/live-run-11da345f98104d92a859a556956c477c/report.json` in the main
checkout. This was one successful full scenario without failures or skips;
it does not establish full Auth or complete stage release acceptance.

The separate acceptance branch at `dc1399187c7d04e814270950d17d160f057c5a52`
passed 62 tests / 82 cases on minimum iOS 26.0. Eighteen Billing HTTP operations
are reviewed against the server and linked to executable tests. Seventeen
identical fixtures are checked by Go, TypeScript and Swift. The other 125
operation mappings remain explicitly pending review. These counts do not
represent production acceptance.

A separate disposable-account suite now compiles on iOS 26. Its runner validates
ownership, build hashes, stage-before-prod and a durable no-retry attempt record;
six local Python regressions pass. The complete account suite passed on minimum iOS 26.0 at `f91974e` (two tests,
zero failures/skips), against stage as a development diagnostic. Its server
account was deleted; a separate reconciliation removed the disposable role under
legacy foreign-key constraints. The same signed `f91974e` suite passed on physical iPhone at 07:50 UTC, with two tests and zero failures/skips; server account/role deletion was verified. This is diagnostic evidence, not acceptance of later SDK changes.
See [the scenario and its limits](../Examples/MMGTExample/AccountsTests/README.md).

## Earlier native and service evidence — 10 September, before 00:43 UTC

SDK `880c682` passed 59 tests / 60 parameterized cases on minimum iOS 26.0 and
on the signed physical iPhone, with zero failures or skips. Swift 6.2 compilation
of all eight products, eight DocC archives and anonymous all-product/Auth-only
consumers also passed. Exact local reports are retained under `.artifacts`:
`tests-20260909T234833Z`, `device-20260909T234917Z`, `compiler-20260909T235016Z`,
`docs-20260909T235158Z` and `public-install-b65ee2809dbd420ab89023395f454ea8`.

The complete passkey → system-browser scenario passed on the physical iPhone at
00:16 UTC: passkey creation, native login, reauthentication, HTTPS OIDC callback,
expected identity, refresh/profile, passkey removal and logout. Report:
`native-run-e35665db9a734910bae91e99080c2b3d/report.json`. This verifies the
ASWebAuthenticationSession HTTPS callback, not ordinary external Universal Link
routing, MFA, all account operations or provider linking.

An isolated application now has its own Codex connection, authorized with the
existing account, with Spark enabled explicitly. No other app's credentials were
copied. Five-service preparation exposed a Python preflight defect: Realtime uses
`base64url(JSON).base64url(HMAC-SHA256)`, not a three-part JWT. The correction checks
encoding, MAC size, exact actor/app/channel/rights and expiry; only the server
verifies the signature. Seven deterministic runner tests cover the wire contract
and rejection boundaries and are included in the local simulator runner.

A separate diagnostic of the unchanged signed `880c682` build passed real Auth,
Sync write/CAS conflict and snapshot recovery, then stopped at Realtime handshake.
The service rejected URLSession's absent `Origin`. Billing and AI were not reached;
no generation was retried. Diagnostic report:
`live-run-21f0ba9111af4490958bb35e2eca23bc/report.json` (kind
`swift-live-diagnostic-run`, not release acceptance). The platform correction adds
an explicit operator opt-in for native handshakes while retaining browser origin
validation, first-frame JWT and channel grants. SDK tests now identify the failing
Realtime phase and safe HTTP/network codes without logging URLs or credentials.

These runner/test changes require a new clean SDK candidate and fresh acceptance.
The following older sections retain historical evidence and their original scope.

## Exact local evidence

SDK `145a481` passed 53 tests / 54 parameterized cases, with zero failures and
skips, both on minimum iOS 26.0 and the signed physical iPhone. Reports:
`.artifacts/tests-20260909T224942Z/report.json` and
`.artifacts/device-20260909T225501Z/report.json`. Swift 6.2 compilation, eight DocC
archives and anonymous all-product/Auth-only installation also passed at that
revision. Reports: `.artifacts/compiler-20260909T225542Z/report.json`,
`.artifacts/docs-20260909T225703Z/report.json` and
`.artifacts/public-install-7b04052b9ec34fd8924239d97ea54cdc/report.json`.
The scene-presentation correction below changes that revision and requires new
exact-candidate evidence; earlier results cannot certify the changed source.

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
shared-fixture tests use the same 17 synthetic JSON files. Entries in
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
its run ID is not reused. The superseded candidate's owned server fixtures and
credential have since been removed, with an independent absence check. Device
Passwords entries are separate from server cleanup. Private evidence:
`.artifacts/native-run-9cc637db5e3f4de1b36e262619db7ef9`.

The separate `MMGTNative` target checks signed Associated Domains and build
hashes, records intent before starting, and requires stage before production.
It does not replace MFA, provider/account-lifecycle or five-service tests.

## Browser presentation after a credential sheet

At `145a481`, the complete native stage scenario twice completed passkey creation,
sign-in and reauthentication, then failed at OIDC browser presentation. A browser
login alone passed on the same physical device and configured application. A
controlled test with one existing passkey reproduced the sequence failure in the
actual example host: the anchor scene was `foregroundInactive` (raw value 1),
the window was key, and AppAuth returned `org.openid.appauth.general:-9` because
the system browser did not start. This evidence does not establish a CDN problem.

Both browser authorizers now wait for the originating visible scene to become
active, with a ten-second bound and cancellation checks. Delayed OIDC task
cancellation is fenced to its own attempt. Fifteen focused tests pass, including
activation ordering, explicit/task cancellation, disconnection and timeout;
`.artifacts/browser-presentation-fix-20260909T2345.xcresult` retains that development
run. The corrected signed existing-account sequence passed at 23:47 UTC: passkey
reauthentication, system-browser login, HTTPS callback, expected account and logout.
Evidence: `.artifacts/oidc-sequence-fixed-20260909T2349/run.json` records exact source
file hashes for this development run. No full native gate or production acceptance
is claimed. Failed physical diagnostics remain under
`.artifacts/oidc-sequence-diagnostic-20260909T2335`; successful browser-only
evidence is under `.artifacts/oidc-diagnostic-20260909T2326`.

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

## Profile contract correction — 10 September

Review of the actual server DTOs found three missing Swift properties: pending
account email and linked-provider email verification/private-relay facts. They
are now optional properties preserving unknown state and existing initializers.
Five additional nonempty shared fixtures cover profile, providers, sessions and
activity/export data; Go, TypeScript and Swift check the same bytes. Eight Auth
HTTP mappings now have explicit source review and executable request/response
tests, including filters, JSON/CSV and failed writes without retry. Together with
Billing, 26 of 143 mappings are reviewed; 117 remain pending. The fixture set now
contains 22 files. The first local simulator run passed 67 tests, zero failures
or skips, on uncommitted preparation; exact-commit, device and release gates
remain separate. No new stable SDK version has been published.

The first exact-commit attempt (`353e6f4`) exposed an incorrect CSV test expectation:
Foundation consumes a leading UTF-8 BOM when decoding text. The test now verifies
the unchanged CSV content and CRLF delimiters after that encoding signature, and
the documentation states this behavior. The failed result remains retained; this
was a test-contract correction, not a silent retry of a provider operation.


## AI continuation contract — 10 September

The Swift tool loop incorrectly sent another `start` while the real server
expected `tool_result`. The corrected loop sends one start and preserves the
socket, checks all calls before executing effects, and refuses changed arguments
under an executed ID. Cancelled/account-obsolete handlers cannot submit late
outputs. The server review also reproduced premature terminal publication and
late terminal results after cancellation; a separately tested platform correction
is required before fresh stage acceptance.

The local iOS 26.0 run passes 77 tests / 111 parameterized cases, zero failures or
skips. This result was obtained on uncommitted preparation. Six AI mappings now
have explicit server source hashes and tests: 32 reviewed of 143, 111 pending.
The shared fixture inventory has 25 entries. Go required PostgreSQL/race and
nine TypeScript tests pass. Actual provider tools/uploads, new exact-candidate
device tests, stage and production remain separate gates. No stable tag is issued.
