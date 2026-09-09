# ``MMGTBilling``

User-facing billing and entitlement operations.

Create `BillingClient` with the application's Billing URL, app ID and session token provider. Public catalog reads do not require user authentication; personal/workspace entitlement and checkout operations do.

Use `BillingAccessState` to reload entitlement state after returning from checkout or the customer portal. A success callback is navigation only: the backend owns the entitlement decision. The SDK does not grant access based on a callback parameter.

The module implements the platform's current Stripe API, including workspace membership, seats and invitations. It does not implement StoreKit, App Store receipt verification or choose a purchasing channel for your app. Evaluate your app's distribution and purchase requirements separately.

<!-- compiled-quickstart -->
## Compiled quickstart

```swift
import MMGTCore
import MMGTAuth
import MMGTBilling

func reloadAccessAfterCheckout(configuration: ServiceConfiguration, session: AuthSession)
  async throws -> BillingAccessResponse
{
  let client = BillingClient(configuration: configuration, tokenProvider: session.tokenProvider)
  return try await client.getAccess()
}
```
<!-- end-compiled-quickstart -->

## Topics
- ``BillingClient``
- ``BillingAccessState``
- ``BillingAccessResponse``
- ``BillingCatalogResponse``
- ``CheckoutRequest``
