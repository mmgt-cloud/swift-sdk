# ``MMGTSync``

Local domain data and scoped synchronization with durable mutation identity and explicit recovery.

Use `LocalReplica` for account-free CRUD, local transactions, observation and durable guest-to-account adoption. See <doc:LocalData>. Existing `SyncClient.write` is an outbox operation, not a complete domain store.

Create `SyncClient` with an application URL, user identity, token provider and local store. Use the optional SQLite module or implement `SyncLocalStore` with the documented atomic operations.

Create records with CAS base version `"0"`; update/delete with the latest observed version where the collection uses `reject_stale`. Versions are decimal strings. Persist mutation IDs before sending. A partial batch acknowledges only returned mutation results; missing results remain in the outbox.

A `SyncScope` canonicalizes collections and workspace IDs. Each scope has its own opaque cursor. Workspace operations need a grant from a domain backend that verifies membership; grants last at most five minutes. Renewing a grant does not change scope identity. `bootstrap(scope:)` obtains the grant for workspace metadata. Its default uses no grant and returns user collection metadata; it is not a filtered feed. The server may also return other user collections and collections authorized by that grant.

`sync` drains pages to its configured bound and returns explicit `hasMore`. Push never advances the pull cursor. Expired history triggers a paginated snapshot. Snapshots expire after 15 minutes; retained history covers 30 days. Recovery preserves outbox and conflicts, moving older pending writes to reconciliation instead of applying them blindly.

The first release targets foreground use and resume. iOS suspension does not guarantee background synchronization.

<!-- compiled-quickstart -->
## Compiled quickstart

```swift
import Foundation
import MMGTSync

func createOfflineNote(client: SyncClient, recordID: String, text: String) async throws
  -> SyncRunResult
{
  let mutationID = UUID().uuidString
  try await client.write(
    .init(
      collection: "notes", recordId: recordID, op: "upsert", data: ["text": .string(text)],
      mutationId: mutationID, baseVersion: "0"))
  return try await client.sync(scope: .init(collections: ["notes"]), maxPages: 100)
}
```
<!-- end-compiled-quickstart -->

## Topics
- <doc:LocalData>
- ``LocalReplica``
- ``ReplicaLocalStore``
- ``ReplicaIdentity``
- ``SyncClient``
- ``SyncScope``
- ``SyncMutation``
- ``SyncRunResult``
- ``SyncState``
- ``SyncLocalStore``
- ``SyncIssue``
