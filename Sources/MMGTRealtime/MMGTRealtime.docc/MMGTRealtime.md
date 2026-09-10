# ``MMGTRealtime``

Authenticated channels with explicit recovery and transport acknowledgments.

Create `RealtimeClient` for one application and user, then subscribe to its message sequence before connecting. Authentication is the first WebSocket frame; ready must identify the expected user. The default readiness deadline is 15 seconds and includes token acquisition.

The native transport does not send a browser `Origin` header. The platform
operator must enable `REALTIME_ALLOW_MISSING_ORIGIN=true` for native handshakes;
this is disabled by default on the server. An HTTP 403 before ready may indicate
that missing configuration. Do not forge a browser origin. First-frame JWT and
channel grants remain mandatory; admitting a handshake does not authenticate it.

Subscriptions retain their channel, presence setting and grant provider across reconnects. Workspace/channel authorization belongs to your domain backend; request a fresh grant when reconnecting. The SDK never embeds signing secrets.

Apply an event's domain effect before calling `acknowledge`. This ACK confirms transport delivery, not that a human read a message. Delivery is at least once; use a stable domain event ID for durable effect deduplication. Event-buffer overflow throws `bufferOverflow`, requiring recovery. On `replayGap`, fetch authoritative domain state.

`FileRealtimeCursorStore` commits acknowledged cursors with revision checks across instances. Backgrounding closes the connection; returning active reconnects a previously desired connection. An explicit disconnect cancels reconnection.

<!-- compiled-quickstart -->
## Compiled quickstart

```swift
import MMGTRealtime

func consumeUserEvents(
  client: RealtimeClient,
  apply: @escaping @Sendable (RealtimeEvent) async throws -> Void,
  reconcile: @escaping @Sendable () async throws -> Void
) async throws {
  let messages = await client.messages()
  try await client.subscribe(.init(channel: RealtimeChannels.user(client.identity.userID)))
  do {
    try await client.connect()
    for try await message in messages {
      switch message {
      case .event(let event):
        try await apply(event)
        try await client.acknowledge(event)
      case .replayGap: try await reconcile()
      default: break
      }
    }
  } catch {
    await client.disconnect()
    throw error
  }
  await client.disconnect()
}
```
<!-- end-compiled-quickstart -->

## Topics
- ``RealtimeClient``
- ``RealtimeState``
- ``RealtimeMessage``
- ``RealtimeEvent``
- ``RealtimeSubscription``
- ``FileRealtimeCursorStore``
