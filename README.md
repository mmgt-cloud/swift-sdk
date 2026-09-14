# MMGT Cloud SDK for iOS

Native Swift clients for MMGT Cloud Auth, Billing, Realtime, Sync and AI. Actors own sessions and connections;
observable state models integrate with SwiftUI without supplying screens.

Version 1.0.0 provides all five service clients, native authentication and
offline guest data with controlled AI access. The accepted runtime and its local,
device, stage and production evidence are described in
[implementation status](docs/implementation-status.md).

## Requirements

- iOS 26 or later; Swift tools 6.2 and Swift 6 language mode.
- A provisioned MMGT Cloud application and its public service configuration.
- Native authentication additionally requires a registered public OIDC client,
  Associated Domains, and the matching Apple application identity.

## Package products

| Product | Purpose |
| --- | --- |
| `MMGTCore` | HTTP/WebSocket transports, configuration, JSON and lifecycle protocols |
| `MMGTAuth` | User endpoints, session ownership, Keychain, native authentication and separate AI guest sessions |
| `MMGTBilling` | Existing Stripe-based platform billing API |
| `MMGTRealtime` | Authenticated WebSocket channels and confirmed replay cursors |
| `MMGTSync` | Offline local replicas, recoverable account import, scoped feeds and mutations |
| `MMGTSyncSQLite` | Transactional SQLite persistence using GRDB |
| `MMGTAI` | Explicit model/connection selection, responses, streams and tools |
| `MMGTSwiftUI` | Application lifecycle integration, without packaged screens |

Source distribution uses Swift Package Manager. Select only the products your
application uses. AppAuth 3.x and GRDB 7.x are package dependencies; their types
are not exposed by the MMGT interfaces. SPM may resolve dependencies even when
their products are not linked into your application.

Add the public repository in Xcode under **File → Add Package Dependencies**,
or use this Swift Package Manager dependency:

```swift
.package(
    url: "https://github.com/mmgt-cloud/swift-sdk.git",
    from: "1.0.0"
)
```

Installation requires no GitHub token or access to the private platform repository.
Tags are immutable; compatible fixes receive a new version.
[Swift Package Index](https://swiftpackageindex.com/mmgt-cloud/swift-sdk) provides
package discovery and versioned DocC hosting. Indexing has a separate acceptance
check; direct Git installation does not depend on index availability.

## Security boundaries

Create clients for one explicit environment and app ID. Session data, Sync
outboxes and Realtime cursors are partitioned by environment, application and
user. Obtain workspace/channel grants from a domain backend that verifies
membership. Never embed administrative API keys, provider keys or deployment
credentials in an iOS app.

Sync preserves pending mutations during snapshot recovery. Realtime delivery
is at least once; transport ACK is not a read receipt. AI generation and tool
effects are not automatically retried. Connections operate while the app is
active; iOS background execution is not guaranteed.

Billing exposes the platform's existing Stripe contract. StoreKit and App Store
purchase verification are outside the first release.

See [privacy declarations](docs/privacy.md) for bundled manifests, transmitted
data and the integrating application's responsibilities.

## Development

All release checks run locally. GitHub Actions is not a release dependency.

```sh
python3 scripts/test.py --destination 'platform=iOS Simulator,id=YOUR-SIMULATOR-ID'
python3 scripts/docs.py
python3 scripts/example.py
```

The runner writes logs and result bundles under the ignored `.artifacts/`
directory. Contract provenance and the operation mapping are in
[`Contracts/platform.json`](Contracts/platform.json). Entries without service
verification or test evidence are not considered accepted.
The [guest contract review](Contracts/GUEST-REVIEW.md) explains the current source
mapping and retained historical evidence. Source review does not imply a passed
device, provider or environment gate.

Use `python3 scripts/check-compiler.py --swiftc /absolute/path/to/swiftc` to
compile all eight products with a specific compiler. This is source compatibility
against the selected Xcode SDK; it does not replace tests on the minimum runtime.
The explicit `--build-system swiftpm --sdk /absolute/path/to/iPhoneSimulator.sdk`
mode uses the compiler's adjacent SwiftPM driver and checks each product for
both arm64 and x86_64 with an iOS 26.0 deployment target. It records the actual
SDK, compiler, lockfile and per-architecture results. This supports a source
check when an installed Xcode cannot resolve its simulator build destinations;
it does not turn an unsuccessful Xcode or device test into a passing result.
The [SwiftUI example](Examples/MMGTExample/README.md) needs only public application
configuration. Shared synthetic wire fixtures are bundled with the test target.

For an unlocked physical device, use
`python3 scripts/test-device.py --device-id YOUR-DEVICE-ID --team-id YOUR-TEAM-ID`.
The runner generates an application-hosted test target and retains its xcresult.
Use `--developer-dir` to select another installed Xcode for that run. The simulator
and DocC runners also require `check-snippets.py` to pass, keeping all eight
quickstarts identical to compiled example sources.

## License

[MIT](LICENSE). Dependencies retain their respective licenses.

## Guest AI and offline data

`LocalReplica` provides local CRUD, multi-record transactions and collection
observation without an account, token or bootstrap request. Its SQLite journal
survives process restarts. Data is partitioned by environment, application and
an explicit guest or account identity. The SwiftUI personal workspace uses these
same operations from both its interface and its example AI tools.

Technical AI `GuestSession` access is separate from ordinary `AuthSession`.
Construction remains offline, Keychain persists an independent renewal credential,
and the AI token provider starts online access only when used. Guest AI must be
explicitly enabled with positive limits and selected models in Panel. AI requires
internet and sends supplied prompts, tool results and attachments to the selected
service/provider even while data synchronization is disabled. See
[Guest AI](Sources/MMGTAuth/MMGTAuth.docc/GuestAI.md).

After complete account authentication, prepare and approve a durable import.
Existing account data requires consent; collisions and collection dependencies
remain application decisions. Import retains the guest copy and original delivery
IDs, and can resume after a restart. Logging out keeps the old account's queue
separate from guest data. See [local data and import](Sources/MMGTSync/MMGTSync.docc/LocalData.md)
and the compiled SQLite quickstart. The original `SyncLocalStore` interface
remains source compatible; local replicas use its extended protocol.

The local `scripts/test.py --destination 'platform=iOS Simulator,id=…'` runner now
also runs `scripts/test-keychain.py` in an application host. Its one real Keychain
CAS test must execute without failures or skips. Physical iPhone, minimum iOS 26,
Swift 6.2 and actual environment/provider acceptance remain separate gates.

The contract matrix distinguishes the guest operations from the 143 historical
reviews. Current release acceptance is tracked in the implementation-status
document; source implementation alone does not establish an environment gate.

The local DocC gate requires a diagnostics file and zero warnings/errors for each
of the eight MMGT products. Dependency documentation diagnostics are retained
separately in the report. Xcode 27 currently reports an unresolved anchor in
GRDB 7.11.1's own documentation; this is not a suppressed MMGT documentation
warning, and vendor sources are unchanged. Public hosting still requires its
separate publication receipt.
