# ``MMGTSyncSQLite``

Optional transactional persistence for Sync.

Open `SQLiteSyncStore` at a private Application Support file URL and inject it into `SyncClient`. GRDB is an implementation dependency; no GRDB types appear in the public interface.

The database keeps account/environment partitions, scoped cursors, records, staged snapshots, outbox and conflict/rejection issues. A page and its cursor commit in one transaction. Snapshot pages remain staged until their final transaction; newer overlapping-feed records and pending local writes are preserved.

Concurrent store instances compare feed revisions before committing. Completed snapshots retain a scope watermark that fences older overlapping pulls and snapshots, including records that were never present locally. The floor, records and final cursor commit atomically. Record versions cannot move backwards. Mutations move atomically between pending and issue state; resolving an attempted mutation creates a new mutation identity.

The database file is excluded from device backup. Deleting the app or the file loses its unsent local changes. Sign-out itself does not erase another account's outbox. The application owns any deliberate data removal/export policy.

<!-- compiled-quickstart -->
## Compiled quickstart

```swift
import Foundation
import MMGTCore
import MMGTAuth
import MMGTSync
import MMGTSyncSQLite

func configureOfflineSync(
  configuration: ServiceConfiguration, userID: String, session: AuthSession, databaseURL: URL
) async throws -> SyncClient {
  let store = try SQLiteSyncStore(fileURL: databaseURL)
  let client = try SyncClient(
    configuration: configuration, userID: userID, tokenProvider: await session.tokenProvider,
    store: store
  )
  await session.attach(client)
  return client
}
```
<!-- end-compiled-quickstart -->

## Topics
- ``SQLiteSyncStore``

## Local database migration

The `v2-snapshot-floors` migration invalidates v1 feed cursors and unfinished snapshot
pages once. Existing visible records remain until a new snapshot replaces them.
Outbox IDs, payloads, original delivery client IDs and conflict/rejection issues
remain intact. Earlier pending mutations require reconciliation with the rebuilt
state; their unknown outcomes are not silently retried under a new identity.
The migration does not delete another account's data. Reopening an upgraded
database preserves its new cursors and snapshot floors.
