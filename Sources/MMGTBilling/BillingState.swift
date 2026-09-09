import MMGTCore

/// Entitlements come from the backend, including after a checkout callback.
public typealias BillingAccessState = ResourceState<BillingAccessResponse>
extension BillingClient {
  @MainActor public func accessState() -> BillingAccessState {
    .init { try await self.getAccess() }
  }
  @MainActor public func catalogState() -> ResourceState<BillingCatalogResponse> {
    .init { try await self.getCatalog() }
  }
}
