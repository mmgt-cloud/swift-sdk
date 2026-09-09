# Implementation and acceptance

Checkpoint: 2026-09-09 21:24 UTC. Development evidence, not a release or a
statement of stage/production readiness. No version tag is available.

| Area | Implementation | Local verification | Stage | Production |
| --- | --- | --- | --- | --- |
| Eight package products | Implemented; operation review continues | All products compile with Swift 6.2 for arm64/x86_64 Simulator | Pending | Pending |
| Auth and native adapters | Session, Keychain, OIDC, passkeys, account operations and provider browser flow | Session/refresh/logout races, storage failures, restricted MFA, callback proofs and cancellation pass | Pending | Pending |
| Billing | User endpoint client | Shared catalog/access/checkout DTO and request checks; full endpoint acceptance pending | Pending | Pending |
| Realtime | WebSocket, deadlines, reconnect, ACK/cursors, deduplication | First-frame auth, foreign-user rejection, bounded ready wait and cursor CAS pass; full failure matrix pending | Pending | Pending |
| Sync and SQLite | Durable outbox, scoped feeds, snapshot staging and conflicts | Restart/isolation, two writers, partial settlement and atomic recovery tests pass | Pending | Pending |
| AI | HTTP, WebSocket, tools, files and cancellation | Shared response/error fixtures, one-socket tool loop, no duplicate execution and interrupted output tests pass | Pending | Pending |
| SwiftUI and example | Observable state, lifecycle, five service tabs and account actions | Example and eight byte-checked DocC quickstarts build with Swift 6.2 on both simulator architectures | Pending | Pending |
| Privacy | Eight SDK manifests and app integration guidance | Actual built app contains the eight manifests plus AppAuth, AppAuthCore and GRDB manifests | App disclosures require review | App disclosures require review |
| DocC | Eight catalogs and local generator | Eight updated archives and compiled quickstarts generated with warnings treated as errors | Not applicable | Public hosting pending |
| Platform native Auth, Panel and ZIP | Implemented in separate platform worktree | Auth PostgreSQL/Redis and race tests; 15 hosted-browser tests in three engines; Panel guards/audits/typecheck; 103 ZIP tests including 64 environment/resource combinations | Pending | Pending |

Latest SDK test report: 52 tests at `948bb98`, iOS 26.3.1 Simulator,
Xcode 26.6 / Swift 6.3.3, 2026-09-09 21:18 UTC.
Earlier notes incorrectly called the simulator runtime 26.5; that is the build
SDK version. xcresult and CoreSimulator identify the runtime as 26.3.1.
Reports are local ignored artifacts and identify development
sources. The five server DTO suites, all five TypeScript client suites (84 tests)
and six Swift shared-fixture tests use the same 11 synthetic JSON files.

Source compatibility was checked with the official Swift 6.2 toolchain and the
Xcode 26.6 / iOS 26.5 SDK. This does not verify execution on iOS 26.0. The installed
Xcode's Swift Testing framework requires the newer compiler, so minimum-compiler
source builds and simulator test results are reported separately. A compatible
minimum-runtime test environment remains required.

All 52 synthetic tests also passed on the signed physical iPhone running iOS 27,
using Xcode 27 beta and the application-hosted target (21:22 UTC), with zero
skipped tests. Actual passkey, Universal Link and provider scenarios remain
pending. Native platform changes have not been deployed.

The current SDK adds opt-in trusted-device support for password/MFA login. It
stores the server cookie in account/app/environment-isolated Keychain, requires
a matching local activation fence, sends trust only to password login, and
rejects late MFA replies after forget or cancellation. Plain transports reject
`rememberDevice: true` rather than silently dropping the cookie. The server
correction enforces the application's current trusted-device policy. These
behaviors are covered locally; their public-service acceptance remains pending.

All eight products compiled with Swift 6.2 at `948bb98`, and all eight DocC
archives were generated with warnings as errors. Reports are under local
`.artifacts/compiler-20260909T211904Z` and `.artifacts/docs-20260909T212010Z`;
physical evidence is `.artifacts/device-trusted-20260909T2122-report.json`.

The full platform local gate passed at `314eb55`: required Go integrations,
race/vet, TS, builds, 123 browser tests, audits, documentation and HA. A new gate
is required for the subsequent trusted-device policy correction. The live iOS
suite compiles separately and fails if its explicit fixture is missing; it has
not yet run against stage or production. An anonymous public consumer at
`605fa3e` built all eight products and an Auth-only app without linking GRDB/SQLite.
That proves revision installation, not a versioned release. Auth npm client
1.1.0 and React 1.0.1 are published and anonymously verified; Swift has its own
version and acceptance process.

Remaining gates: complete the operation matrix and deterministic failure cases,
complete live native device scenarios,
release locally through stage then production, verify actual Panel ZIPs, publish
immutable tags and GitHub Release, submit to Swift Package Index, verify hosted
DocC and install the public package anonymously in a clean consumer.
