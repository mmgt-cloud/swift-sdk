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
