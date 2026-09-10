import Foundation
import MMGTAI
import MMGTCore
import MMGTRealtime
import Synchronization
import Testing

actor TestSocket: WebSocketConnection {
  var sent: [JSONValue] = []
  var incoming: [JSONValue]
  var receivers: [CheckedContinuation<JSONValue, any Error>] = []
  var observers: [(Int, CheckedContinuation<Void, Never>)] = []
  var receiveCalls = 0
  var receiveObservers: [(Int, CheckedContinuation<Void, Never>)] = []
  var isClosed = false
  init(_ incoming: [JSONValue] = []) { self.incoming = incoming }
  func send(_ value: JSONValue) throws {
    guard !isClosed else { throw MMGTError.streamInterrupted }
    sent.append(value)
    let ready = observers.filter { $0.0 < sent.count }
    observers.removeAll { $0.0 < sent.count }
    for (_, observer) in ready { observer.resume() }
  }
  func receive() async throws -> JSONValue {
    receiveCalls += 1
    let ready = receiveObservers.filter { $0.0 <= receiveCalls }
    receiveObservers.removeAll { $0.0 <= receiveCalls }
    for (_, observer) in ready { observer.resume() }
    if !incoming.isEmpty { return incoming.removeFirst() }
    if isClosed { throw MMGTError.streamInterrupted }
    return try await withCheckedThrowingContinuation { receivers.append($0) }
  }
  func push(_ value: JSONValue) {
    if !receivers.isEmpty {
      receivers.removeFirst().resume(returning: value)
    } else {
      incoming.append(value)
    }
  }
  func waitForSend(_ index: Int) async {
    if sent.count > index { return }
    await withCheckedContinuation { observers.append((index, $0)) }
  }
  func waitForReceiveCall(_ count: Int) async {
    if receiveCalls >= count { return }
    await withCheckedContinuation { receiveObservers.append((count, $0)) }
  }
  func close() {
    isClosed = true
    let pending = receivers
    receivers.removeAll()
    for receiver in pending { receiver.resume(throwing: MMGTError.streamInterrupted) }
  }
}

actor TokenGate {
  var continuation: CheckedContinuation<String, Never>?
  var observer: CheckedContinuation<Void, Never>?
  var started = false
  func token() async -> String {
    started = true
    return await withCheckedContinuation {
      continuation = $0
      observer?.resume()
      observer = nil
    }
  }
  func wait() async {
    if started { return }
    await withCheckedContinuation { observer = $0 }
  }
  func resolve() {
    continuation?.resume(returning: "late-token")
    continuation = nil
  }
}

@Suite(.timeLimit(.minutes(1))) struct WebSocketTests {
  func config(_ service: String) throws -> ServiceConfiguration {
    try .init(baseURL: URL(string: "https://example.invalid/\(service)")!, appID: "app-a")
  }
  let ready: JSONValue = ["type": "ready", "connection_id": "connection-a", "user_id": "user-a"]
  func response(status: String = "completed", calls: [AIToolCall]? = nil) -> AIResponse {
    .init(
      id: "response-a", status: status, provider: "test-provider", model: "test-model",
      text: "complete", toolCalls: calls,
      usage: .init(inputTokens: 1, outputTokens: 1, totalTokens: 2))
  }
  func input() -> AIResponseRequest {
    .init(
      connectionId: "connection-a", model: "test-model",
      input: [.init(role: "user", content: [.text("hello")])])
  }

  @Test func realtimeAuthenticatesInFirstFrameAndRejectsForeignUser() async throws {
    let socket = TestSocket()
    let urls = Mutex<[URL]>([])
    let client = try RealtimeClient(
      configuration: config("realtime"), userID: "user-a", tokenProvider: { "test-token" },
      autoReconnect: false,
      socketFactory: { url in
        urls.withLock { $0.append(url) }
        return socket
      })
    let connecting = Task { try await client.connect() }
    await socket.waitForSend(0)
    let first = await socket.sent[0]
    #expect(first == ["type": "auth", "app_id": "app-a", "access_token": "test-token"])
    #expect(urls.withLock { $0.first?.absoluteString } == "wss://example.invalid/realtime/ws")
    await socket.push(["type": "ready", "connection_id": "wrong", "user_id": "user-b"])
    await #expect(throws: MMGTError.sessionChanged) { try await connecting.value }
    #expect(await client.state == .closed)
    await client.close()
  }
  @Test func readyDeadlineIncludesNonCooperativeTokenProvider() async throws {
    let gate = TokenGate()
    let creations = Mutex(0)
    let client = try RealtimeClient(
      configuration: config("realtime"), userID: "user-a", tokenProvider: { await gate.token() },
      autoReconnect: false, readyTimeout: .milliseconds(30),
      socketFactory: { _ in
        creations.withLock { $0 += 1 }
        return TestSocket()
      })
    let connecting = Task { try await client.connect() }
    await gate.wait()
    await #expect(throws: MMGTError.connectionTimeout) { try await connecting.value }
    await gate.resolve()
    await client.close()
    #expect(creations.withLock { $0 } == 0)
  }
  @Test func realtimeCursorOnlyAdvancesAfterAcknowledgementAndDedupeIsPerConnection() async throws {
    let socket = TestSocket()
    let cursors = MemoryRealtimeCursorStore()
    let client = try RealtimeClient(
      configuration: config("realtime"), userID: "user-a", tokenProvider: { "test-token" },
      cursorStore: cursors, autoReconnect: false, socketFactory: { _ in socket })
    try await client.subscribe(.init(channel: "user:user-a"))
    let stream = await client.messages()
    var iterator = stream.makeAsyncIterator()
    let connecting = Task { try await client.connect() }
    await socket.waitForSend(0)
    await socket.push(ready)
    try await connecting.value
    _ = try await iterator.next()
    await socket.waitForSend(1)
    let wire: JSONValue = [
      "type": "event", "id": "100-0", "channel": "user:user-a", "event_type": "message",
      "payload": ["domainID": "domain-a"], "sent_at": "2026-09-09T12:00:00Z",
    ]
    await socket.push(wire)
    guard case .event(let event) = try await iterator.next() else {
      Issue.record("Expected event")
      return
    }
    #expect(
      try await cursors.load(identity: client.identity, channel: event.channel).eventID == nil)
    try await client.acknowledge(event)
    await socket.push(wire)  // suppressed duplicate before ack confirmation
    await socket.push([
      "type": "ack_confirmed", "channel": "user:user-a", "event_id": "100-0",
      "acked_at": "2026-09-09T12:00:01Z",
    ])
    guard case .acknowledged = try await iterator.next() else {
      Issue.record("Duplicate event leaked")
      return
    }
    #expect(
      try await cursors.load(identity: client.identity, channel: event.channel).eventID == "100-0")
    await client.close()
  }
  @Test func aiToolLoopKeepsOneSocketAndNeverReexecutesCallIDs() async throws {
    let call = AIToolCall(id: "call-a", name: "lookup", arguments: ["key": "value"])
    let action: JSONValue = [
      "type": "response.requires_action",
      "response": try .encoding(response(status: "requires_action", calls: [call])),
      "requestId": "r",
    ]
    let complete: JSONValue = [
      "type": "response.completed", "response": try .encoding(response()), "requestId": "r",
    ]
    let socket = TestSocket([["type": "authenticated"], action, action, complete])
    let creates = Mutex(0)
    let executions = Mutex(0)
    let client = AIClient(
      configuration: try config("ai"), tokenProvider: { "test-token" },
      socketFactory: { _ in
        creates.withLock { $0 += 1 }
        return socket
      })
    var request = input()
    request.tools = [.init(name: "lookup", parameters: ["type": "object"])]
    let result = try await client.runTools(
      request,
      tools: [
        "lookup": { _, _ in
          executions.withLock { $0 += 1 }
          return ["answer": "found"]
        }
      ])
    #expect(result.status == "completed")
    #expect(creates.withLock { $0 } == 1)
    #expect(executions.withLock { $0 } == 1)
    #expect(
      await socket.sent.compactMap { $0["type"]?.string } == [
        "authenticate", "start", "tool_result", "tool_result",
      ])
    #expect(
      await socket.sent[2] == [
        "type": "tool_result", "callId": "call-a", "output": ["answer": "found"],
      ])
    #expect(await socket.isClosed)
  }
  @Test func aiPartialTextIsNotSuccessfulCompletion() async throws {
    let socket = TestSocket([
      ["type": "authenticated"], ["type": "output.text.delta", "delta": "partial"],
    ])
    let client = AIClient(
      configuration: try config("ai"), tokenProvider: { "test-token" },
      socketFactory: { _ in socket })
    let stream = try await client.stream(input())
    var iterator = stream.makeAsyncIterator()
    #expect(try await iterator.next() == .textDelta("partial"))
    await socket.close()
    await #expect(throws: MMGTError.streamInterrupted) { _ = try await iterator.next() }
    #expect(await socket.sent.filter { $0["type"]?.string == "start" }.count == 1)
  }
  @Test func fileCursorCASProtectsAgainstOtherInstances() async throws {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "mmgt-cursors-\(UUID())/cursors.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let a = try FileRealtimeCursorStore(fileURL: url)
    let b = try FileRealtimeCursorStore(fileURL: url)
    let identity = try AccountIdentity(configuration: config("realtime"), userID: "user-a")
    let initial = try await a.load(identity: identity, channel: "user:user-a")
    #expect(
      try await b.compareAndSet(
        identity: identity, channel: "user:user-a", expected: initial, eventID: "200-0") != nil)
    #expect(
      try await a.compareAndSet(
        identity: identity, channel: "user:user-a", expected: initial, eventID: "100-0") == nil)
    #expect(try await a.load(identity: identity, channel: "user:user-a").eventID == "200-0")
  }
}
