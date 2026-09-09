# ``MMGTAI``

Explicit AI requests, WebSocket streams and application-owned tools.

Create `AIClient` with the application's AI endpoint and the session token provider. Fetch the catalog, then explicitly choose a connection ID and model for every response. Do not assume every connection supports the same optional parameters; select only supported capabilities.

Ordinary generation uses HTTP. Platform streaming uses WebSocket and exposes `AIStreamEvent` values. `AIState` retains partial text with an interrupted status when a stream ends unexpectedly or is canceled. Its output buffer is bounded. Only a completed response is complete; a tool request remains `requiresAction`.

`runTools` keeps one WebSocket across bounded tool turns. Register only tools your application authorizes. Tool IDs and arguments are checked to prevent accidental repeated execution in the same run. Your backend/domain must still make effects idempotent across restarts and independent runs.

Generation, fallback and tool effects are never automatically retried. A transient error may report that retry is possible; retry remains an explicit application/user decision. Backgrounding cancels active requests and streams.

<!-- compiled-quickstart -->
## Compiled quickstart

```swift
import MMGTAI

func generateReply(client: AIClient, connectionID: String, model: String, prompt: String)
  async throws -> AIResponse
{
  let request = AIResponseRequest(
    connectionId: connectionID, model: model,
    input: [.init(role: "user", content: [.text(prompt)])])
  return try await client.generate(request)
}
```
<!-- end-compiled-quickstart -->

## Topics
- ``AIClient``
- ``AIState``
- ``AIResponseRequest``
- ``AIStreamEvent``
- ``AIToolRegistry``
