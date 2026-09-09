import MMGTCore

/// Exposes bounded-run progress (`hasMore`) without scheduling hidden background work.
public typealias SyncState = ResourceState<SyncRunResult>
extension SyncClient {
  @MainActor public func state(
    scope: SyncScope = try! SyncScope(), maxPages: Int = 100, limit: Int = 500
  ) -> SyncState {
    .init { try await self.sync(scope: scope, maxPages: maxPages, limit: limit) }
  }
}
