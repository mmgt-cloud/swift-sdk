import Foundation
import MMGTCore
import MMGTRealtime
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1))) struct RealtimeContractTests {
  let channel = "workspace:synthetic"
  let user = "22222222-2222-4222-8222-222222222222"
  func wire(_ name: String) throws -> JSONValue {
    try SharedWireContractTests().decode("realtime-" + name)
  }
  func client(_ socket: TestSocket, store: any RealtimeCursorStore = MemoryRealtimeCursorStore())
    throws -> RealtimeClient
  {
    try .init(
      configuration: .init(
        baseURL: URL(string: "https://example.invalid/realtime")!,
        appID: "11111111-1111-4111-8111-111111111111"), userID: user,
      tokenProvider: { "synthetic-valid-token" }, cursorStore: store, autoReconnect: false,
      socketFactory: { _ in socket })
  }
  func open(_ client: RealtimeClient, _ socket: TestSocket) async throws {
    let task = Task { try await client.connect() }
    await socket.waitForSend(0)
    await socket.push(try wire("ready"))
    try await task.value
  }

  @Test func sharedFramesPreserveRequestsConfirmedCursorAndPresence() async throws {
    let socket = TestSocket()
    let store = MemoryRealtimeCursorStore()
    let client = try client(socket, store: store)
    let previous = try await store.load(identity: client.identity, channel: channel)
    _ = try await store.compareAndSet(
      identity: client.identity, channel: channel, expected: previous, eventID: "1725883200000-0")
    try await client.subscribe(
      .init(channel: channel, presence: true, grantProvider: { _ in "synthetic-grant" }))
    var states = await client.connectionStates().makeAsyncIterator()
    #expect(await states.next() == .idle)
    var messages = await client.messages().makeAsyncIterator()
    try await open(client, socket)
    #expect(try await messages.next() == RealtimeMessage(wire: wire("ready")))
    #expect(await states.next() == .open)
    #expect(client.identity.userID == user)
    #expect(await client.connectionID == "synthetic-connection")
    await socket.waitForSend(1)
    #expect(try await socket.sent[0] == wire("auth"))
    #expect(try await socket.sent[1] == wire("subscribe"))
    #expect(await client.getSubscriptions().map(\.channel) == [channel])
    for name in ["snapshot", "joined", "left", "subscribed"] {
      let frame = try wire(name)
      await socket.push(frame)
      #expect(try await messages.next() == RealtimeMessage(wire: frame))
      if name == "snapshot" {
        #expect(await client.getPresence(channel: channel).first?.connectionCount == 2)
      }
      if name == "joined" {
        #expect(await client.getPresence(channel: channel).first?.connectionCount == 3)
      }
      if name == "left" { #expect(await client.getPresence(channel: channel).isEmpty) }
    }
    let published = try wire("publish")
    try await client.publish(
      channel: channel, eventType: "synthetic.changed", payload: published["payload"]!,
      grant: "synthetic-grant")
    #expect(await socket.sent.last == published)
    // A grant rejection is actionable and must not destroy an otherwise authenticated socket.
    await socket.push(try wire("error"))
    #expect(try await messages.next() == RealtimeMessage(wire: wire("error")))
    #expect(await client.state == .open)
    try await client.unsubscribe(channel)
    #expect(try await socket.sent.last == wire("unsubscribe"))
    await socket.push(["type": "unsubscribed", "channel": .string(channel)])
    #expect(try await messages.next() == .unsubscribed(channel: channel))
    #expect(await client.getSubscriptions().isEmpty)
    await client.close()
  }

  @Test func confirmedCursorSurvivesRestartAndReplayGapInvalidatesIt() async throws {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "mmgt-rt-restart-\(UUID())/cursors.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let firstSocket = TestSocket()
    let firstStore = try FileRealtimeCursorStore(fileURL: url)
    let first = try client(firstSocket, store: firstStore)
    let eventWire = try wire("event")
    let event = try eventWire.decode(RealtimeEvent.self)
    try await first.subscribe(.init(channel: event.channel))
    var messages = await first.messages().makeAsyncIterator()
    try await open(first, firstSocket)
    _ = try await messages.next()
    await firstSocket.waitForSend(1)
    await firstSocket.push(eventWire)
    #expect(try await messages.next() == .event(event))
    try await first.acknowledge(event)
    #expect(
      try await firstStore.load(identity: first.identity, channel: event.channel).eventID == nil)
    await firstSocket.push(try wire("ack"))
    _ = try await messages.next()
    #expect(
      try await firstStore.load(identity: first.identity, channel: event.channel).eventID
        == event.id)
    await first.close()
    let secondSocket = TestSocket()
    let secondStore = try FileRealtimeCursorStore(fileURL: url)
    let second = try client(secondSocket, store: secondStore)
    try await second.subscribe(.init(channel: event.channel))
    var recovered = await second.messages().makeAsyncIterator()
    try await open(second, secondSocket)
    _ = try await recovered.next()
    await secondSocket.waitForSend(1)
    #expect(await secondSocket.sent[1]["resume_after"] == .string(event.id))
    await secondSocket.push(eventWire)
    #expect(try await recovered.next() == .event(event))  // dedupe is scoped to the connection
    var gap = try wire("gap").decode([String: JSONValue].self)
    gap["channel"] = .string(event.channel)
    await secondSocket.push(.object(gap))
    #expect(try await recovered.next() == .replayGap(channel: event.channel, fromEventID: event.id))
    #expect(
      try await secondStore.load(identity: second.identity, channel: event.channel).eventID == nil)
    let otherEnvironment = try AccountIdentity(
      configuration: .init(
        baseURL: URL(string: "https://prod.example.invalid/realtime")!, appID: second.identity.appID
      ), userID: user)
    #expect(
      try await secondStore.load(identity: otherEnvironment, channel: event.channel).eventID == nil)
    await second.close()
  }

  @Test func oneObserverCancellationDoesNotCloseAnotherFeedOrConnection() async throws {
    let socket = TestSocket()
    let client = try client(socket)
    let stream = await client.messages()
    let observing = Task { for try await _ in stream {} }
    var surviving = await client.messages().makeAsyncIterator()
    try await open(client, socket)
    _ = try await surviving.next()
    observing.cancel()
    try await observing.value
    let future: JSONValue = ["type": "synthetic_future", "payload": false]
    await socket.push(future)
    #expect(try await surviving.next() == .unknown(future))
    #expect(await client.state == .open)
    await client.close()
    // Closing emits a final connection error and then finishes every message feed.
    _ = try await surviving.next()
    #expect(try await surviving.next() == nil)
    await #expect(throws: MMGTError.sessionChanged) { try await client.connect() }
  }

  @Test(arguments: ["", "bad channel", "a/../b", "é", String(repeating: "a", count: 129)])
  func invalidChannelsNeverReachTransport(_ channel: String) async throws {
    let socket = TestSocket()
    let client = try client(socket)
    #expect(throws: (any Error).self) { try RealtimeSubscription(channel: channel) }
    await #expect(throws: (any Error).self) {
      try await client.publish(
        channel: channel, eventType: "event", payload: false, grant: "synthetic-grant")
    }
    #expect(await socket.sent.isEmpty)
    await client.close()
  }
}
