# Platform compatibility

`platform.json` maps the npm client surface to native Swift APIs. Its source-file
hashes identify the private platform declarations reviewed for this development
candidate. The private repository is never an installation or test dependency of
this package. A dirty platform revision is explicitly recorded.

Each operation records its native mapping, kind, implementation status and test
references. `serverVerified: false` and pending local, device or environment
acceptance remain open gates. A mapped method does not establish endpoint or
provider correctness. Native adaptations describe deliberate differences from
browser APIs; generic transport extensions are separated from service operations.
Internal TypeScript helper classes do not belong to the public service matrix.

The test target contains 55 synthetic shared JSON fixtures under
`Tests/MMGTTests/Fixtures/v1`. Their manifest, checksums and semantic tests run
without the platform checkout. The platform mirrors their exact bytes and tests
the actual Go and TypeScript DTOs/clients against them. A selected fixture is
evidence only for its scenario, not the entire service.

`privacy.json` is the reviewed per-module manifest inventory. It describes SDK
data transmission and source API use; integrating apps must assess their own
schemas, provider requests, entitlements and privacy disclosures.

The Billing server review now names the immutable platform source files and
checksums separately from the original npm snapshot. Its 18 HTTP operations have
explicit endpoint tests, including authenticated/public headers and request/response
bodies. Six added fixtures cover nonempty catalog, access, workspace and invitation
data. These checks do not represent actual Stripe payments or device acceptance.

Run `python3 scripts/check-contracts.py` to check evidence references and fixture
integrity using only this public checkout. Maintainers can optionally pass
`--platform-source <local-checkout>` to detect server declaration drift and compare
shared bytes. Missing reviews remain counted as pending; integrity validation does
not change their acceptance status. The ordinary simulator runner executes this
check and its regression tests before compiling the package.

The AI review covers all six mapped runtime operations. Shared catalog, upload and
tool-result fixtures supplement the response/error fixtures. HTTP tests verify
multipart bytes, selected identity and explicit model, and no retry after failures.
Socket tests verify one start, bounded tool rounds, call-ID reuse, cancellation
and incomplete streams. The server review identifies the pending terminal-state
correction by source hashes; it does not claim that correction is deployed.

Sixteen Auth entry operations now have explicit wire tests and server review.
The same fixtures distinguish complete tokens, password expiry, required MFA,
flagged/legacy enrollment and actionable CAPTCHA/lockout errors. The TypeScript
review found empty token strings incorrectly counted as a session (NSDK-04);
that pending platform change is recorded by its source hash. Swift already
rejects empty token pairs. Email/provider delivery remains separate acceptance.

The Sync review covers the four public endpoints and native local-store/lifecycle
adaptations. The same bootstrap/push/pull/snapshot fixtures are read by Go, TS and
Swift. Fault tests cover overlapping snapshots, stale responses after cancellation,
partial batches, restart and the v1 SQLite migration. NSDK-05 also corrects the
corresponding IndexedDB ordering problem; publication and environment acceptance
remain pending for both SDK implementations.

Twenty-four MFA, phone, backup-email and trusted-device endpoint mappings now have
explicit method/body/authentication tests. Six fixtures preserve TOTP binary data,
recovery codes, effective method flags, unverified addresses/numbers and device
metadata. NSDK-06 records pending server corrections to SMS availability flags
and the ORM-backed e-mail setting lookup. These tests do not establish delivery
of SMS/e-mail, an enrollment on a physical device or production availability.

Twenty-two account/configuration and raw passkey endpoints now have explicit
route, body, identity and response tests. Seven new fixtures cover configuration,
validation, merge, nonempty credentials and the full nested WebAuthn options.
Session adaptations have generation, refresh, persistence and Keychain fault
evidence. Generic HTTP extensions are tested separately from service operations;
NSDK-07 rejects CRLF/control bytes before transport. System authentication UI
and real provider effects still require their own acceptance.

All eight remaining native Auth adaptations have source and local evidence.
Tests inspect the actual AppAuth authorization request (PKCE S256, independent
state/nonce, exact callback and no secret), native platform passkey request bytes,
provider linking proof and cancellation ordering. NSDK-08 fences a delayed
passkey cancellation to its originating ceremony. The complete matrix now has
143 reviewed operations; no operation remains unreviewed. These local checks do not
replace browser/device ceremonies, Associated Domains or provider acceptance.

Realtime adds eleven shared frames (55 fixtures total). All 16 runtime mappings
have explicit server and test references. The native API intentionally uses
confirmed, identity-scoped cursor progress and manual ACK; it does not expose the
browser client's last-ACK timestamp or persist each received event automatically.
A delayed completed-connect cancellation cannot stop reconnect (NSDK-09).
Grant refresh, lifecycle, observer cancellation, restart and replay-gap tests are
local evidence; actual network/device and environment fault acceptance remain open.

## Guest and local-replica candidate (2026-09-12)

The original 143-operation review is historical. The matrix now includes separate
pending mappings for GuestSession and LocalReplica; earlier results do not cover
these additions. There are 58 synthetic fixtures, including guest credentials,
policy, AI authorization and the bound Sync bootstrap identity. Their public
source remains this repository. The private platform mirrors exactly these bytes.
GuestSession implementation uses separate Keychain credentials; SQLite replica
and example integration are still in progress. No new stable release is claimed.
