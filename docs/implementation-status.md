# Implementation and acceptance

Updated 2026-09-14. The tested runtime candidate is
`1881f3bcc77f6626ab0cb36a13564b88071521d8`, paired with platform
`dcc09540dc1e847d53cf5425e7a7412e2e6cf045`. All eight package products and the
163 reviewed operations are implemented. The matrix and 59 synthetic fixtures
are described in [the contract review](../Contracts/GUEST-REVIEW.md).

The complete stage gate passed at `2026-09-13T22:24:13.358024+00:00` (57 checks); the complete
production gate passed at `2026-09-14T03:08:42.493205+00:00` (58 checks). Production promoted the same
backend image digests and its separately built frontend. Version 1.0.0 adds final
documentation to the accepted SDK runtime; code, tests, fixtures, scripts, package
manifest and lockfile retain the same Git objects. Distribution checks use the
actual immutable release tag and are separate from these runtime measurements.

| Scope | Evidence for the runtime candidate |
| --- | --- |
| Local package and minimum runtime | 159 package tests, one hosted Keychain test and seven personal-example tests passed on both iOS 26.0 and iOS 27; no failures or skips |
| Minimum compiler | All eight products compiled with Swift 6.2 for arm64 and x86_64 Simulator; this is separate from the minimum-runtime test |
| Physical iPhone | 167 package, Keychain and personal-example tests passed on iOS 27; live authentication and provider results are separate |
| Stage | Complete 57-check platform/native/guest gate passed, including provider ceremonies, guest AI and web/Swift import, cleanup and 30 minutes of observation |
| Production | Rollout, five live services, guest AI and web/Swift import, native passkeys, Google/Apple linking and reauthentication, OIDC/MFA, Universal Links, account lifecycle, AI files/tools/cancellation, Stripe TEST inbox, network isolation, SMTP receipt and the iOS ZIP passed; the eleven-message native email lifecycle and Stripe TEST personal/workspace/add-on checkout scenarios also passed. Natural offsite application recovery on the healthy cluster, retention, owned cleanup and at least 30 continuous minutes of operational observation also passed |
| Distribution | The immutable 1.0.0 public tag identifies the documentation release. Fresh DocC, anonymous versioned AllProducts/AuthOnly consumers and public hosting are independent distribution checks; they do not relabel the runtime tests |

The approved simulator offline acceptance is sufficient for release. The separate
optional physical offline scenario also passed on stage with the device radios
disabled. Neither result claims that AI works offline: AI requires internet and
transmits the supplied context to the configured provider.

Evidence is bound to the exact SDK/platform sources, signed build artifacts,
original xcresult counts and immutable release receipts. A documentation-only
release commit must record its runtime-source equivalence and run the relevant
documentation/public-install checks; older tests must not be renamed as new runs.

The production native consumer uses a separately reviewed test-only correction
`6427bcb4b8d288a938d750bb24a85ba4a45a8d0a` for the system password chooser and
translucent Paste menu. Its corrected core suite passed on stage before production;
the runtime SDK and platform were unchanged. Failed earlier attempts are retained.
The passkey rerun passed after the operator removed historical test credentials;
that sequence does not establish the cause of the earlier association failure.

Historical iterations and their original limitations are retained in the
[dated archive](archive/2026-09-13-implementation-checkpoints.md). They do not
describe current deployment state. This page is updated only when the corresponding
acceptance or publication evidence exists.
