# SwiftUI example

This is a development example, not a stable SDK acceptance report. All screens
are owned by the example; the package provides clients and observable state.

From the SDK repository root, with Xcode 26+ and XcodeGen 2.46+ installed:

```sh
python3 scripts/example.py
open Examples/MMGTExample/MMGTExample.xcodeproj
```

The generator creates an ignored `Configuration.json` from synthetic
placeholders only when it is missing. Replace its values with one application's
public service configuration. It never needs an admin/API-provider key,
client secret, Kubernetes credentials or access to the platform repository.
Use separate application configuration for stage and production.

To build without signing:

```sh
xcodebuild build \
  -project Examples/MMGTExample/MMGTExample.xcodeproj \
  -scheme MMGTExample -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

For native browser sign-in and passkeys, choose your signing team and registered
Bundle ID in Xcode. Add the `webcredentials:` and `applinks:` Associated Domains
for the exact RP/callback host, and obtain operator approval for the matching
Team ID/Bundle ID/callback registration. Downloading SDK source alone does not
establish domain trust. Passkeys and Universal Links require device acceptance.

The example saves notes to a durable outbox before network transmission. The
configured `notes` collection must be a writable user collection whose schema
accepts an object with a string `text` property. Creation uses CAS version `0`.
Workspace grants must be supplied by an authorized domain backend if you extend
this example to workspace collections.

Realtime subscribes to the signed-in user's channel and explicitly acknowledges
applied events. Billing reloads entitlements and does not initiate a payment.
AI sends only on the explicit button press, with the connection/model you select;
there is no retry or fallback. Use a short prompt and a test connection.

The example demonstrates password, verification-code MFA, browser OIDC and
passwordless passkey entry points. The account tab lists sessions, passkeys and
linked providers, registers a passkey, links a provider through the system browser
and starts email change after password reauthentication. These operations are
bound to the current session and discard late results after logout. A lost
provider-finish response requires reloading linked accounts before starting again.
Provider, passkey and domain-association acceptance remain separate release gates;
the example does not imply native authentication is already deployed.

After building, verify the actual bundled privacy resources with
`python3 scripts/check-privacy.py --application /absolute/path/to/MMGTExample.app`.
Review [privacy declarations](../../docs/privacy.md) for your own collection schema,
provider use and App Store disclosures.

The project also hosts `MMGTDeviceTests`, using the package's synthetic test
sources and fixtures. Run it on a physical device with the SDK's
`python3 scripts/test-device.py --device-id YOUR-DEVICE-ID --team-id YOUR-TEAM-ID`.
This signs and installs the example/test host on that device. Its synthetic tests
do not perform provider, domain-association or live passkey acceptance. Those
scenarios require the configured example and a deployed native backend.

The separate [native acceptance target](NativeTests/README.md) verifies actual
passkeys and the system-browser HTTPS callback on a signed iPhone. Its runner
sets `MMGT_EXAMPLE_ENTITLEMENTS` for the example host only and checks the signed
domains. Ordinary builds leave that setting empty. Native acceptance requires
explicit fixture ownership, operator-reviewed AASA and interaction on the phone.

The separate [account acceptance target](AccountsTests/README.md) exercises
sessions, TOTP, recovery codes, password changes and deletion against a disposable
real Auth account. It requires an explicit private fixture and records each
attempt before making requests; it never runs in the ordinary package suite.

## Personal space: offline guest → AI → account

The first tab opens personal lists, tasks, notes and chat history without making a
network request. The sample configuration is sufficient for local CRUD. A public
profile identifier is persisted atomically before opening the SQLite replica. The
profile index contains no credentials; guest AI credentials use the SDK Keychain,
without iCloud. The database and retained guest copy are durable application data.
Deleting the application/container removes the only local copy of unsynchronized work.
The sample does not support app extensions sharing its profile-index file; use a
coordinated profile repository before adding another process.

The UI and assistant use `PersonalDomain` and the same `LocalReplica` transactions.
Deleting a personal list detaches its tasks and notes in that transaction. The four
collections must be provisioned using [the shared schema fixture](../../Tests/MMGTTests/Fixtures/v1/sync-personal.json)
before enabling account Sync. These schemas are distinct from the older Sync-tab
`notes` demonstration and from web Demo's authenticated SQL collaboration data.

The first explicit catalog/upload request starts the technical guest AI session.
The app owner must enable guest AI in Panel with exact models and positive limits.
The user selects a connection/model and confirms each mutating tool. Tool results
can disclose local data to the provider; AI is online even when Sync is disabled.
File-picker uploads are temporary, expire after an hour, and are never saved as
permanent IDs in the local chat collections. Cancellation preserves partial text as
incomplete and never repeats generation or a tool automatically.

On an offline restart, a previously authenticated identity can reopen its local data
only while its local Keychain activation fence remains valid. That identity is not
an online Auth session: account AI/Sync wait for successful Auth restoration or full
login, including MFA. Logout clears the Auth fence and closes the current profile;
a previous account's outbox remains isolated, and an adopted guest backup is never
presented as a fresh guest account. Late UI callbacks and assistant tools are fenced
to the profile they started with.

A confirmed account receives a fresh snapshot. Empty accounts may adopt automatically;
existing data requires an import summary and explicit collision decisions. Background
sync pauses while the summary awaits consent. A change from another local writer
makes it stale; use **Review guest data** again. List dependencies and stable mutation
IDs survive restart. Guest source data stays retained after the atomic local transfer.
A rejected or conflicted mutation stays visible for explicit reconciliation.

`scripts/test.py` now also runs `scripts/test-personal.py` in the compiled example host,
with synthetic transport and real SQLite. It requires six executed tests, no skips,
and writes a separate report. The ordinary package suite and real hosted Keychain
check remain separate required checks. iPhone, providers, two-device synchronization,
minimum OS/compiler and stage/prod acceptance are additional gates.
