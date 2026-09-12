# Guest and local-replica contract review — 2026-09-12

Platform source: `3d5a4cf` in the private platform repository. Current exact file
hashes are in `platform.json`. The previous complete matrix, its original review
scopes and hashes remain in `Archive/2026-09-12-before-guest-review.json`; the
current matrix records the archive digest and every changed source hash.

This review closes the **source mapping** of the 20 new guest/local operations,
bringing the reviewed matrix to 163 operations. It does not close stage,
production, physical-device, provider or publication acceptance. Those states
remain separate in the operation entries and release receipts. No private
credentials or live user data are part of these public fixtures.

## Auth guest boundary

The ordinary Auth user client and guest session remain separate. Creating and
renewing a technical session use `POST /auth/guest/sessions` and its `/renew`
suffix with `X-App-ID` and a `renewal_secret` body. Revoke uses `/revoke` and returns
204. Responses carry explicit app, issuer, `ai` purpose, guest identity, opaque
access credential, access expiry and inactivity expiry. The client validates
these values and retains the original renewal secret before the first request.
The server uses its own application/policy/session locking, not a caller-supplied
installation identity, to resume creation and serialize renewal/revocation.

The GET validation route is distinct from user JWT validation. Policy updates
remain administrative; they are not an iOS SDK capability. Disabled, expired,
unauthorized, invalid and throttled outcomes stay explicit and are not converted
to a new account, silent guest reset or generation retry. Swift's Keychain CAS,
shared in-flight task and generation fence implement the native counterpart to
the TS isolated store. Local summary/observation/close do not contact Auth.

Reviewed tests include Go concurrent creation/renewal, app/issuer/purpose/expiry,
policy CAS and revocation, source/app caps, purge, fail-closed database handling,
and user/admin route separation. The operation entries identify exact Swift
tests for persistence, lost responses, cancellation, terminal states and observer
completion. Hosted Keychain acceptance is recorded separately from memory tests.

## LocalReplica and Sync

The optional local-store extension leaves existing custom `SyncLocalStore`
consumers usable. Local CRUD, observation, transactions, conflict resolution and
import journal access have no new public server route. Environment, application
and explicit guest/user identity select the local partition. Local revisions do
not become server versions; the existing user feed retains string versions,
opaque scoped cursors, grant checks, snapshots and CAS.

Network connection confirms app/user identity from authenticated bootstrap. The
new optional `X-Sync-User-ID` header is a mismatch fence and grants no access.
Import preparation reads a fresh snapshot without pushing the account's pending
queue. It requires user-scoped CAS collections, full authentication and consent
when the selected account collections contain data. Approval creates the target
copy, immutable delivery IDs and dependency order atomically while retaining the
guest copy. No mutation changes an existing server record's owner. User switches
close old requests/replicas and preserve the former account queue.

SQLite/IndexedDB transaction failure, disk full, previous schema migration,
concurrent connections, delayed responses, partial delivery and account-bound
resumption are covered by explicit local tests. A synthetic second-store test
is not a substitute for public web-to-iPhone interoperability.

## AI and existing domains

HTTP and first-frame WebSocket authentication accept the guest credential through
the separate current Auth policy validator. Catalog/model selection is explicit;
each provider round revalidates and reserves shared admission before dispatch.
Files gain principal ownership for upload/use/delete while retaining encryption
and expiry. Legacy ownerless uploads remain unavailable to guests and ordinary
users. Administrative expiry cleanup remains available. Guest errors preserve
their 401/403/410/429/503 distinction; no retry/fallback was added.

The tool observer addition in TS maps to Swift's `runTools` event callback. Both
clients validate/correlate tool calls, fence cancellation and do not repeat tool
effects after duplicate frames. Example applications apply their own domain
validation and explicit confirmation. A bounded local history preserves an
interrupted reply instead of silently truncating a completed answer.

The previously reviewed Billing DTOs remain valid. The refreshed source review
also includes two existing native-release corrections: access/workspace reads
no longer abandon open checkouts, and invite routes return the delivery result
updated by the Email attempt. Their Go integration tests cover both behaviors.
Ordinary Auth, native OIDC/passkey and Realtime boundaries retain their existing
contracts; adding guest routes does not authorize guests to enter those flows.

## Executed local evidence and pending release

The platform Go normal/race and type/build tests passed before the documentation
inventory stopped the implementation quality attempt at `09bcaff`. That is a
failed overall gate, not release acceptance. The refreshed guest browser consumer
has synthetic transport tests and a compiled browser bundle; its live runner
requires a new clean candidate and records one provider attempt durably.

Swift package tests (158), real hosted Keychain and the personal-example suite
(seven) passed on iOS 26.0 and 27.0. Swift 6.2 source compilation passed for all
eight products on arm64 and x86_64 using the explicit installed iOS 26.5 SDK via
SwiftPM. These source/minimum-runtime checks remain distinct. Final clean-commit
receipts, the physical iPhone, public services, actual ZIPs and publication are
still required before stable release.
