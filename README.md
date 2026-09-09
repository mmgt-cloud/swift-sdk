# MMGT Cloud SDK for iOS

Native Swift clients for MMGT Cloud Auth, Billing, Realtime, Sync and AI. Actors own sessions and connections;
observable state models integrate with SwiftUI without supplying screens.

**Under development. No stable release has been published.** The first stable
release requires the completed native authorization flow, device testing and
stage/production acceptance. See [implementation status](docs/implementation-status.md).

## Requirements

- iOS 26 or later; Swift tools 6.2 and Swift 6 language mode.
- A provisioned MMGT Cloud application and its public service configuration.
- Native authentication additionally requires a registered public OIDC client,
  Associated Domains, and the matching Apple application identity.

## Package products

| Product | Purpose |
| --- | --- |
| `MMGTCore` | HTTP/WebSocket transports, configuration, JSON and lifecycle protocols |
| `MMGTAuth` | User endpoints, session ownership, Keychain and native authentication |
| `MMGTBilling` | Existing Stripe-based platform billing API |
| `MMGTRealtime` | Authenticated WebSocket channels and confirmed replay cursors |
| `MMGTSync` | Scoped feeds, mutations, recovery and local store protocol |
| `MMGTSyncSQLite` | Transactional SQLite persistence using GRDB |
| `MMGTAI` | Explicit model/connection selection, responses, streams and tools |
| `MMGTSwiftUI` | Application lifecycle integration, without packaged screens |

Source distribution uses Swift Package Manager. Select only the products your
application uses. AppAuth 3.x and GRDB 7.x are package dependencies; their types
are not exposed by the MMGT interfaces. SPM may resolve dependencies even when
their products are not linked into your application.

There is no stable installation version yet. During development, open this
checkout in Xcode or add it as a local package dependency. Release instructions
will name an immutable version only after that version has been published.

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

## Development

All release checks run locally. GitHub Actions is not a release dependency.

```sh
python3 scripts/test.py --destination 'platform=iOS Simulator,id=YOUR-SIMULATOR-ID'
```

The runner writes logs and result bundles under the ignored `.artifacts/`
directory. Contract provenance and the operation mapping are in
[`Contracts/platform.json`](Contracts/platform.json). Entries without service
verification or test evidence are not considered accepted.

## License

[MIT](LICENSE). Dependencies retain their respective licenses.
