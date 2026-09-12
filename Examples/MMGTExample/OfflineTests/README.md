# Physical offline acceptance

`MMGTOffline` uses a separate tiny consumer, bundle `cloud.mmgt.sdkoffline`.
It cannot restore the main example's accounts or initiate its startup requests.
The test uses the real SDK, SQLite, Keychain and the iOS `NWPathMonitor`.
It fails while Wi-Fi or cellular data provides a satisfied path. No mocked
transport, simulator setting or successful cloud test substitutes for that check.

Build locally before asking the device owner to disconnect the phone:

```sh
python3 scripts/test-offline.py build --device-id "$IPHONE_ID" \
  --team-id "$APPLE_TEAM_ID" --developer-dir "$DEVELOPER_DIR"
```

The build uses a generic physical-device target, so a disconnected phone does
not block compilation. The stored device ID selects the actual test destination.
Place a mode-600 JSON file under ignored `.artifacts` with `environment`, `appID`,
`foreignAppID` and a fresh UUID `runID`. It contains no credentials. The platform
acceptance wrapper verifies that both applications belong to the disposable run.

Connect the phone over USB, unlock it, then disable cellular data and Wi-Fi on
the phone. Keep the Mac online. Run:

```sh
python3 scripts/test-offline.py run --build-report "$OFFLINE_BUILD_REPORT" \
  --configuration "$OFFLINE_CONFIGURATION"
```

Production additionally requires `--stage-report` from the same SDK commit.
The runner executes two separate `test-without-building` processes. The first
creates a fresh local profile and records. The second compares the full persisted
snapshots and original delivery IDs, then updates, deletes and observes records.
Sixteen partitions cover two applications, two environments, two principal IDs
and guest/user kinds in the same SQLite database. Guests keep a local journal;
account partitions retain their own unconnected outboxes. Local versions are
never reported as server versions. No Auth, AI or Sync operation is invoked.

An attempt marker prevents an uncertain first start from being relabelled as
fresh. Failed runs remain failed; diagnose and create a new explicit run. The
platform cleanup removes this isolated test app after recording acceptance.
Restore normal phone connectivity after the run. Actual example UI, guest AI,
account import and web interoperability have separate required receipts.
