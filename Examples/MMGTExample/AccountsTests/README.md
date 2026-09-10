# Disposable account acceptance

The separate `MMGTAccounts` scheme executes the actual public Auth API. It is
excluded from ordinary package tests. It changes a test account's profile,
sessions, MFA and password, then permanently deletes that account.

Use only a newly prepared `account-sdk-<32 lowercase hex digits>@example.invalid`
account in a platform-owned smoke application with TOTP enabled. The platform
operator prepares an already verified disposable identity; this scenario does
not establish delivery of registration, magic-link or password-reset emails.
It also does not replace browser MFA, provider linking or passkey acceptance.

Build a clean SDK commit before preparing private fixture input:

```sh
python3 scripts/test-accounts.py build \
  --destination 'platform=iOS Simulator,id=YOUR-SIMULATOR-ID'
```

For a physical iPhone, use `platform=iOS,id=YOUR-DEVICE-ID`, supply `--team-id`,
and optionally `--developer-dir`. The phone must be unlocked to start the host;
the account scenario itself needs no interactive authentication.

The private JSON input has exactly these fields: `environment`, `appID`,
`userID`, `runID`, `email`, `password`, `replacementPassword`, `authURL`. Store
it with mode 0600 in `.artifacts`. The URL must be the exact selected
environment's public `/auth` URL. Never commit this input or embed it in the
example's public `Configuration.json`.

```sh
python3 scripts/test-accounts.py run \
  --build-report .artifacts/accounts-build-BUILD-ID/report.json \
  --configuration .artifacts/owned-account.json
```

The runner checks the clean commit and build hashes, journals the attempt
before execution, passes secrets only through the runner environment, and
retains private logs and an xcresult. Reusing an attempted `runID` is rejected.
After an interruption, inspect the recorded phase and reconcile the owned
server account before preparing a new attempt. There is no automatic retry.
The two expected test results are a known TOTP counter vector and the complete
account scenario; skips or partial execution do not pass acceptance.

Production requires `--stage-report` from this exact SDK commit; a physical
production run requires physical stage evidence. The platform additionally
binds results to its deployed release, app ownership and cleanup journal.

The scenario verifies current-session reads, revocation of a second session,
refresh persistence, TOTP enrollment, restricted temporary-token access,
incorrect-code rejection, recovery-code replay rejection, password rotation,
old-token rejection and final server/local account cleanup. TOTP checks wait
for a fresh counter rather than retrying a spent code. Concurrent one-time
credential consumption remains a separate server integration test.
