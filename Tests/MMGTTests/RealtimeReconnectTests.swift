import Foundation
import MMGTCore
import Synchronization
import Testing

@testable import MMGTRealtime

@Suite(.timeLimit(.minutes(1))) struct RealtimeReconnectTests {
  func eventually(_ condition: @escaping @Sendable () async -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while ContinuousClock.now < deadline {
      if await condition() { return true }
      try await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
  }

  @Test func completedWaiterCancellationCannotStopAutomaticReconnect() async throws {
    let sockets = [TestSocket(), TestSocket()]
    let created = Mutex(0)
    let tokens = Mutex(0)
    let grants = Mutex(0)
    let client = try RealtimeClient(
      configuration: .init(
        baseURL: URL(string: "https://example.invalid/realtime")!, appID: "app-a"),
      userID: "user-a",
      tokenProvider: {
        tokens.withLock {
          $0 += 1
          return "synthetic-token-\($0)"
        }
      },
      autoReconnect: true,
      socketFactory: { _ in
        try created.withLock { count in
          guard count < sockets.count else {
            throw MMGTError.invalidResponse("Unexpected reconnect")
          }
          defer { count += 1 }
          return sockets[count]
        }
      })
    try await client.subscribe(
      .init(
        channel: "workspace:synthetic",
        grantProvider: { _ in
          grants.withLock {
            $0 += 1
            return "synthetic-grant-\($0)"
          }
        }))
    let messages = await client.messages()
    var events = messages.makeAsyncIterator()
    try await RealtimeRecoveryTests().connect(client, sockets[0])
    _ = try await events.next()
    await sockets[0].waitForSend(1)
    await sockets[0].close()
    guard case .error = try await events.next() else {
      Issue.record("Expected interrupted socket")
      return
    }
    // Deliver cancellation of a waiter that already completed. Such an ID is
    // absent from the registry; the action must not affect the replacement.
    await client.cancelConnect(UUID())
    let authenticated = try await eventually { await sockets[1].sent.count >= 1 }
    #expect(authenticated)
    if authenticated {
      await sockets[1].push(["type": "ready", "connection_id": "connection-b", "user_id": "user-a"])
      let subscribed = try await eventually { await sockets[1].sent.count >= 2 }
      #expect(subscribed)
      #expect(await client.state == .open)
      #expect(await client.connectionID == "connection-b")
      #expect(await sockets[1].sent.first?["access_token"] == "synthetic-token-2")
      #expect(await sockets[1].sent.last?["grant"] == "synthetic-grant-2")
    }
    await client.close()
  }
  @Test func activeConnectCancellationDoesNotCreateASocketFromALateToken() async throws {
    let gate = TokenGate()
    let created = Mutex(0)
    let client = try RealtimeClient(
      configuration: .init(
        baseURL: URL(string: "https://example.invalid/realtime")!, appID: "app-a"),
      userID: "user-a", tokenProvider: { await gate.token() }, autoReconnect: true,
      socketFactory: { _ in
        created.withLock { $0 += 1 }
        return TestSocket()
      })
    let connecting = Task { try await client.connect() }
    await gate.wait()
    connecting.cancel()
    await #expect(throws: CancellationError.self) { try await connecting.value }
    await gate.resolve()
    // Even a non-cooperative provider cannot create a connection after close.
    await client.close()
    #expect(await client.state == .closed)
    #expect(created.withLock { $0 } == 0)
  }

  @Test func lifecycleReconnectsOnlyPreviouslyDesiredConnections() async throws {
    let sockets = [TestSocket(), TestSocket()]
    let created = Mutex(0)
    let client = try RealtimeClient(
      configuration: .init(
        baseURL: URL(string: "https://example.invalid/realtime")!, appID: "app-a"),
      userID: "user-a", tokenProvider: { "synthetic-token" }, autoReconnect: true,
      socketFactory: { _ in
        try created.withLock { count in
          guard count < sockets.count else { throw MMGTError.invalidResponse("Unexpected socket") }
          defer { count += 1 }
          return sockets[count]
        }
      })
    try await RealtimeRecoveryTests().connect(client, sockets[0])
    await client.activityChanged(.inactive)
    #expect(await client.state == .open)
    await client.activityChanged(.background)
    #expect(await sockets[0].isClosed)
    #expect(await client.connectionID == nil)
    let foreground = Task { await client.activityChanged(.active) }
    await sockets[1].waitForSend(0)
    await sockets[1].push(["type": "ready", "connection_id": "connection-b", "user_id": "user-a"])
    await foreground.value
    #expect(await client.connectionID == "connection-b")
    await client.disconnect()
    await client.activityChanged(.background)
    await client.activityChanged(.active)
    #expect(await client.state == .closed)
    #expect(created.withLock { $0 } == 2)
    await client.activityChanged(.signedOut)
    await #expect(throws: MMGTError.sessionChanged) { try await client.connect() }
  }

}
