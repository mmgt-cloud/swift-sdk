# Local data without an account

`LocalReplica` provides a materialized domain view over confirmed records and a durable local journal. Construction, reads and multi-record transactions require neither a token nor bootstrap. Supply a stable locally generated guest profile ID, an explicit application/environment configuration, collection names, and a `ReplicaLocalStore` such as `SQLiteSyncStore`.

A guest identity is distinct from `AccountIdentity`. Guest replicas never push or pull. Auth's separate `GuestSession` only grants controlled online AI access; it is not a Sync account. AI tools should invoke the same validated `LocalReplica.transaction` operations as the UI. The application owns tool schemas, permissions, confirmation of destructive operations and conversation history. Sending prompts, tool results or attachments to AI sends those supplied data to the configured service/provider even when Sync is disabled.

## Local writes and observation

Transactions read their own writes, coalesce repeated edits to a record within the transaction and commit every record intent plus its journal atomically. Throwing from the synchronous callback rolls back all changes. Concurrent writers compare the complete partition revision; `ReplicaError.staleRevision` asks the application to re-read and decide, rather than silently re-executing its domain callback.

`ReplicaRecord.serverVersion` is an observed server decimal string or nil. `localRevision` is a separate local counter. Pending edits remain visible over confirmed data, including conflict/rejection issues. A push acknowledgement updates confirmed state without waiting for a later pull, but never overrides a newer snapshot floor. Consecutive edits to one record wait for their predecessor's acknowledged CAS version. An attempted request preserves its mutation and delivery client IDs across restart or lost responses.

`changes()` emits coalesced complete snapshots. SQLite observation polls at 200 ms while subscribed, so writes from another connection/process are visible. Cancel the observation when inactive and resubscribe on foreground; it does not promise background execution. Closing a replica fences late tool/network results and cancels its outstanding writes. Instantiate a separate replica when switching accounts. Logout preserves the old account partition; it does not expose it as guest data.

## Connect and adopt

After normal Auth has completed all required MFA, connect a user replica using its account token provider. The SDK checks the bootstrap application/user and sends the expected-user header on Sync requests. The current local layer uses personal `user` collections with `reject_stale`; workspace collaboration continues to use `SyncClient` with domain-issued grants.

Call `guest.prepareImport(to: account)` with replicas sharing one store instance. It obtains a fresh account snapshot without pushing or reconciling existing account outbox entries. The returned plan is durable and contains source IDs, target collisions and whether consent is required. All populated guest collections must be included in the account's collection configuration.

An empty destination can be adopted automatically. Existing data requires explicit confirmation. A collision additionally requires `replaceTarget` or `keepTarget`; a pending or conflicted destination cannot be overwritten. Optional application decisions may transform validated data and declare dependencies by collection/record ID. The SDK does not infer that similar records represent the same object. Cycles or missing dependencies reject the whole transaction. Imported children wait for acknowledged parent mutations; a rejected parent sends dependent work to reconciliation.

`approveImport` reads the stored plan again, validates its actual data using the account's validator and checks both partition revisions. On success, target records/queue, the import journal and the source adoption marker commit together. The source copy remains stored and becomes read-only, bound to that one account. Retrying a committed plan returns its original mutation IDs. Reopen the same partitions after restart and use `importProgress` and `synchronize` to finish outstanding work; partial server results do not create new delivery identities.

If a source or destination changed after planning, prepare a new plan. Approval only commits local work; server validation can still create visible issues. `resolveIssue` resolves the affected record's entire pending chain to the current server value or a validated replacement with a new CAS mutation. Ordinary uncertain attempted requests must obtain their result before replacement. Cursor-expiry reconciliation is explicit.

## Recovery and storage limits

SQLite v3 adds metadata/import tables and preserves existing environment/account keys, records, cursors, outbox, issues and original delivery identities. Existing v1 databases still run the older v2 snapshot-floor recovery first. The SDK never assigns an ambiguous unscoped third-party database to a guest or account automatically; an application-specific migration must establish ownership first.

Disk-full and SQL errors fail the complete transaction. No success is reported before commit, and no in-memory fallback discards durability. The journal and retained guest copy currently remain until the application deliberately removes its local database; no automatic compaction deletes unsent work. Deleting the app/database can lose unsynchronized data. AI upload IDs have a separate one-hour lifetime and are not durable domain attachment references.
