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

`connect()` completes when the authenticated `ready` frame is received. Grant
acquisition and channel subscriptions continue afterward; observe `subscribed`
and error messages for each channel. A grant rejection requires action by the
application. Publishing never silently retries after an uncertain send.

Swift always uses manual ACK. A received event, `subscribed` metadata or a publish
return value does not advance the stored cursor. `RealtimeCursorStore.load`
returns this installation's confirmed event ID and revision, not a server ACK
timestamp. Keys include the service URL, application, user and channel. After a
replay gap the confirmed cursor is cleared; rebuilding authoritative data remains
the application's responsibility. The new connection may deliver the same domain
event again, so durable effect deduplication belongs to that application.

Cancel an observing task to stop only its feed. `disconnect()` stops reconnects
and retains desired subscriptions for an explicit future `connect()`; `close()`
or sign-out permanently closes this client. Cancellation of a completed connect
attempt cannot cancel a replacement connection. No continuous WebSocket service
is promised while iOS suspends the application.

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
