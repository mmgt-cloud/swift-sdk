# Explicit live-service acceptance

`MMGTLiveTests` is an application-hosted test target, separate from ordinary SDK
tests. It exercises real Auth password/session/logout, Sync user CAS and snapshot
recovery with SQLite, Realtime subscription/publication/transport ACK, Billing
reads and one explicit AI HTTP request plus one WebSocket response. It never
retries generation, publishes again after an uncertain result, or skips a missing
dependency. Native browser/MFA, passkeys, workspace grants, actual checkout and
Associated Domains need their own acceptance evidence.

Use a dedicated, disposable application and account in the selected environment.
The application must have a writable `user` collection with `reject_stale` policy
and a schema accepting `{ "text": "..." }`. Prepare a Realtime grant with publish
and subscribe rights to exactly `sdk-live:<runID>`, an existing enabled AI
connection/model, and the corresponding Billing user configuration. The smoke
does not provision resources or contain administrative credentials. Fixture
provisioning, reconciliation and cleanup belong to an ownership-fenced operator
procedure. Preserve the run ID until all remote data has been reconciled.

Build from a clean SDK commit before issuing the short-lived grant:

```sh
python3 scripts/test-live.py build \
  --destination 'platform=iOS Simulator,id=YOUR-SIMULATOR-UUID'
```

For a physical iPhone select `platform=iOS,id=YOUR-DEVICE-ID`, supply `--team-id`
and, if necessary, `--developer-dir`. Global Xcode selection is not changed.

Put the private JSON in `.artifacts/live-configuration.json` with mode `0600`.
Required fields are `environment` (`stage` or `prod`), `appID`, `userID`, `email`,
`password`, UUID `runID`, `collection`, HTTPS `authURL`, `billingURL`,
`realtimeURL`, `syncURL`, `aiURL`, `realtimeGrant`, `aiConnectionID` and `aiModel`.
All service URLs must belong to the selected public platform environment. Use
the actual service base paths from the application's current configuration.
The grant must have at least three minutes of validity remaining when the test
starts. The service verifies its signature and scope; the runner's expiry check
is only a preflight.

```sh
python3 scripts/test-live.py run \
  --build-report .artifacts/live-build-BUILD-ID/report.json \
  --configuration .artifacts/live-configuration.json
```

Production additionally requires `--stage-report` pointing to a passing live
report for the exact same SDK commit. This is one gate within the complete
release process, not permission to bypass native Auth or platform stage gates.

Credentials are passed through Apple's `TEST_RUNNER_` environment mechanism,
never command arguments, generated source, bundles, Markdown or report fields.
The runner creates private logs/xcresult bundles under `.artifacts`; Xcode may
record its launch environment there. Treat the entire directory as confidential.
Reports contain only commit, environment, run ID, tools, test counts and outcome.
Do not publish raw Xcode logs, xcresult bundles or live configuration. Remove
credentials and revoke fixture access after operator cleanup.

Timeouts or any failed phase stop this run. Inspect private evidence and reconcile
the fixture before starting a new run; a disconnected response does not establish
whether its server-side mutation completed. Missing configuration fails explicitly
and cannot turn into a passing zero-test run.
