# ``MMGTCore``

Shared configuration, transport and lifecycle interfaces.

Create one `ServiceConfiguration` for each service endpoint and application. URLs must use HTTPS. The SDK sends the application identifier and, for authenticated operations, obtains a user token from your `AccessTokenProvider`.

Use `JSONValue` for arbitrary payloads; integral values retain their full 64-bit representation. Sync versions stay decimal strings. `WireDate` accepts RFC 3339 timestamps, including fractional seconds.

HTTP transport does not follow redirects, retry operations or silently switch environments. `APIError` preserves HTTP status, platform code and request ID. A canceled operation throws `CancellationError`.

`ResourceState` offers observable loading/data/error state with cancellation and generation checks. Create new resource state when the account changes; signed-out instances cannot be reused.

<!-- compiled-quickstart -->
## Compiled quickstart

```swift
import Foundation
import MMGTCore

func configureService(baseURL: URL, appID: String) throws -> ServiceConfiguration {
  try ServiceConfiguration(baseURL: baseURL, appID: appID)
}
```
<!-- end-compiled-quickstart -->

## Topics
### Configuration and identity
- ``ServiceConfiguration``
- ``AccountIdentity``
- ``JSONValue``
- ``WireDate``
### Networking
- ``HTTPClient``
- ``HTTPTransport``
- ``WebSocketConnection``
- ``APIError``
### Application state
- ``ResourceState``
- ``ApplicationLifecycleParticipant``

Additional headers cannot replace `Authorization`, `X-App-ID`, `Host` or cookies.
Names must use the HTTP token alphabet. Values reject control bytes, including
CRLF, NUL and DEL; horizontal tabs are permitted. Validation happens before
transport. Cancellation rejects late results, but cannot promise rollback of a
write already accepted by the server. Reconcile an uncertain write explicitly.
