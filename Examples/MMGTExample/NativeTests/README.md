# Physical native authentication acceptance

`MMGTNative` is separate from ordinary package tests and the five-service smoke.
It requires a real iPhone and user interaction with AuthenticationServices.
Missing fixture, signing, AASA, passkey or browser completion fails the test;
simulator execution cannot qualify.

Use a fresh disposable account with no passkeys in one application. Register the
public OIDC client in Panel with the signing Team ID, Bundle ID
`cloud.mmgt.sdkexample`, existing RP domain and exact `/native/…` HTTPS callback.
The operator must approve that registration. Test stage before production. Do not
change the RP ID of existing accounts or grant an unreviewed app shared-domain trust.

Build from a clean SDK checkout before creating any authentication fixture:

```sh
python3 scripts/test-native.py build --environment stage \
  --device-id YOUR-PHYSICAL-DEVICE-ID --team-id YOUR-TEAM-ID
```

Use `--developer-dir /absolute/path/to/Xcode.app/Contents/Developer` when the
device requires another installed Xcode. The runner generates a private
entitlements file containing only the selected environment's `applinks:` and
`webcredentials:` domains. Xcode obtains the matching provisioning profile.
The runner verifies the actual signed application identity and domains and
records hashes of the application, test bundle and `.xctestrun` artifact.

Create a mode-0600 JSON file under the SDK's ignored `.artifacts` directory with
exactly these fields: `environment`, `appID`, `userID`, `email`, `password`,
UUID `runID`, `authURL`, `teamID`, `bundleID`, `relyingPartyID`, `clientID` and
`redirectURL`. Use an owned account with a synthetic `@example.invalid` email;
this scenario does not send email. The client ID is public. Passwords and user
tokens never belong in bundled example configuration or command arguments.

```sh
python3 scripts/test-native.py run \
  --build-report .artifacts/native-build-BUILD-ID/report.json \
  --configuration .artifacts/native-configuration.json
```

Keep the iPhone unlocked. Confirm native passkey creation, sign-in and
reauthentication when prompted. In the system browser, select passkey sign-in,
confirm the same fixture credential and finish consent. The test verifies the
actual HTTPS callback, account identity, refresh and profile. It removes its
server-side passkey record and logs out after success. Apple Passwords may retain
the synthetic credential; remove only the fixture credential after acceptance.
Its display name and the private report identify the test run.

The runner passes credentials through Apple's `TEST_RUNNER_` environment, never
source or app resources. Xcode can include launch environment in logs/results;
treat the entire `.artifacts` directory as confidential. Public reports should
contain only reviewed outcomes, source revisions, environment, test counts and
safe hashes. Do not publish raw result bundles or authorization URLs.

Each run ID is claimed durably before starting. A failed or interrupted attempt
cannot retry automatically: inspect private evidence, reconcile registration and
sessions, and clean up the owned account/application before another explicit run.
Production requires `--stage-report` for a passing native run at the same SDK
commit, in addition to the platform's complete stage gate.

This scenario does not establish MFA enrollment, external Google/Apple account
linking, Billing checkout or all five services. Those retain separate acceptance
gates. A successful local compile is not evidence of passkey or domain-association
operation on an actual device.
