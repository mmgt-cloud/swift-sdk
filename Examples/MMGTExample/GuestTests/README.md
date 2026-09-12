# Guest product acceptance

`MMGTGuest` is an explicit live test scheme, outside ordinary unit tests. It
requires an isolated application with guest AI enabled, an existing Codex model,
the four personal collections, and a fully authenticated test account. The web
companion must first import a note titled `Imported from web guest` with the
configured `webRecordID`. It verifies the same ID after Swift changes its title
to `Edited by Swift`, and reads `swiftRecordID` created by the Swift guest tool.

The scenario first writes and reopens SQLite without any Auth/Sync request. It
then resumes a real Keychain guest session, makes one HTTP generation, uploads
synthetic text and runs a confirmed local tool through the WebSocket tool loop.
After normal account authentication it rejects an unconfirmed merge, imports the
guest note, preserves the source copy and synchronizes both original record IDs.
The fixture grants confirmation for exactly one synthetic note; this does not
provide a general application confirmation policy.

Build with `python3 scripts/test-guest.py build --destination <explicit-device>`
and `--team-id <team>` for a physical device. The runner uses ad-hoc signing for
the simulator's real Keychain. Run with `python3 scripts/test-guest.py run
--build-report <report> --configuration <private-json>`; production also requires
`--stage-report <successful-sdk-report>`. Configuration must be mode 600 under
the ignored `.artifacts` directory, with `environment`, `appID`, `userID`, `runID`,
`email`, `password`, `authURL`, `syncURL`, `aiURL`, `webRecordID`, `swiftRecordID`,
`aiConnectionID` and `aiModel`. Exact environment URLs and record UUIDs are checked
before execution. No application or provider key is part of this client fixture.

Each run ID is durably marked before execution, both on the computer and in the
app. A failed or interrupted attempt requires reconciliation and a new explicit
fixture; neither generation nor its tools are automatically repeated. The test
revokes its guest session and removes its upload. Platform fixture cleanup owns
remote account/record deletion. Reports contain outcome and artifact references;
private credentials and API bodies are never interpolated into test failures.

This is one product scenario. It does not replace the separate quota/failure,
multi-browser, physical offline-launch, account-race, native Auth or actual ZIP
acceptance gates. A successful build alone is not a provider or device receipt.
