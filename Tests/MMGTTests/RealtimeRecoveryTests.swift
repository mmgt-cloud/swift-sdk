import Foundation
import MMGTCore
import MMGTRealtime
import Testing

@Suite(.timeLimit(.minutes(1))) struct RealtimeRecoveryTests {
  let ready: JSONValue = ["type": "ready", "connection_id": "connection-a", "user_id": "user-a"]
  func client(_ socket: TestSocket) throws -> RealtimeClient {
    try .init(
      configuration: .init(
        baseURL: URL(string: "https://example.invalid/realtime")!, appID: "app-a"),
      userID: "user-a", tokenProvider: { "synthetic-token" }, autoReconnect: false,
      socketFactory: { _ in socket })
  }
  func connect(_ client: RealtimeClient, _ socket: TestSocket) async throws {
    let task = Task { try await client.connect() }
    await socket.waitForSend(0)
    await socket.push(ready)
    try await task.value
  }

  @Test func presenceCountsAreAuthoritativeAndClearedOnDisconnect() async throws {
    let socket = TestSocket()
    let client = try client(socket)
    try await client.subscribe(.init(channel: "user:user-a", presence: true))
    let stream = await client.messages()
    var messages = stream.makeAsyncIterator()
    try await connect(client, socket)
    _ = try await messages.next()
    await socket.waitForSend(1)
    await socket.push([
      "type": "presence_snapshot", "channel": "user:user-a",
      "users": [["user_id": "user-a", "connection_count": 2]],
    ])
    _ = try await messages.next()
    #expect(await client.getPresence(channel: "user:user-a").first?.connectionCount == 2)
    await socket.push([
      "type": "presence_joined", "channel": "user:user-a", "user_id": "user-a",
      "connection_count": 3,
    ])
    _ = try await messages.next()
    #expect(await client.getPresence(channel: "user:user-a").first?.connectionCount == 3)
    await socket.push(["type": "presence_left", "channel": "user:user-a", "user_id": "user-a"])
    _ = try await messages.next()
    #expect(await client.getPresence(channel: "user:user-a").isEmpty)
    await socket.push(["type": "presence_joined", "channel": "user:user-a", "user_id": "user-a"])
    _ = try await messages.next()
    #expect(await client.getPresence(channel: "user:user-a").first?.connectionCount == 1)
    await client.disconnect()
    #expect(await client.getPresence(channel: "user:user-a").isEmpty)
    #expect(await client.getSubscriptions().map(\.channel) == ["user:user-a"])
    await client.close()
  }

  @Test func lateGrantCannotRestoreAnUnsubscribedOrReplacedSubscription() async throws {
    let socket = TestSocket()
    let client = try client(socket)
    try await connect(client, socket)
    let gate = TokenGate()
    let old = Task {
      try await client.subscribe(
        .init(channel: "workspace:synthetic", grantProvider: { _ in await gate.token() }))
    }
    await gate.wait()
    try await client.unsubscribe("workspace:synthetic")
    try await client.subscribe(
      .init(channel: "workspace:synthetic", presence: true, grantProvider: { _ in "new-grant" }))
    await gate.resolve()
    await #expect(throws: CancellationError.self) { try await old.value }
    let subscriptions = await socket.sent.filter { $0["type"]?.string == "subscribe" }
    #expect(subscriptions.count == 1)
    #expect(subscriptions.first?["grant"]?.string == "new-grant")
    #expect(subscriptions.first?["presence"] == .bool(true))
    #expect(await client.state == .open)
    await client.close()
  }

  @Test func slowConsumerReceivesExplicitOverflowAndCanOpenANewFeed() async throws {
    let socket = TestSocket()
    let client = try client(socket)
    try await client.subscribe(.init(channel: "user:user-a"))
    let slow = await client.messages()
    try await connect(client, socket)
    await socket.waitForSend(1)
    for index in 0..<300 {
      await socket.push([
        "type": "event", "id": .string("\(index)-0"), "channel": "user:user-a",
        "event_type": "synthetic",
        "payload": [:], "sent_at": "2026-09-09T12:00:00Z",
      ])
    }
    await socket.waitForReceiveCall(302)
    await #expect(throws: MMGTError.bufferOverflow) {
      for try await _ in slow {}
    }
    let fresh = await client.messages()
    var messages = fresh.makeAsyncIterator()
    await socket.push(["type": "replay_gap", "channel": "user:user-a", "from_event_id": "1-0"])
    #expect(try await messages.next() == .replayGap(channel: "user:user-a", fromEventID: "1-0"))
    await client.close()
  }
}
