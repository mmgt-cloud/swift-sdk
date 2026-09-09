import Foundation
import MMGTCore

public actor RealtimeClient: ApplicationLifecycleParticipant {
  public nonisolated let identity: AccountIdentity
  public private(set) var state: RealtimeConnectionState = .idle {
    didSet { for observer in stateObservers.values { observer.yield(state) } }
  }
  public private(set) var connectionID: String?
  private let configuration: ServiceConfiguration
  private let tokenProvider: AccessTokenProvider
  private let factory: WebSocketFactory
  private let cursors: any RealtimeCursorStore
  private let autoReconnect: Bool
  private let readyTimeout: Duration
  private var attempt = UUID()
  private var socket: (any WebSocketConnection)?
  private var worker: Task<Void, Never>?
  private var deadline: Task<Void, Never>?
  private var backoff: Task<Void, Never>?
  private var retryCount = 0
  private var permanent = false
  private var desired = false
  private var resumeAfterBackground = false
  private var stateObservers: [UUID: AsyncStream<RealtimeConnectionState>.Continuation] = [:]
  private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
  private var listeners: [UUID: AsyncThrowingStream<RealtimeMessage, any Error>.Continuation] = [:]
  private var subscriptions: [String: RealtimeSubscription] = [:]
  private var cursorState: [String: RealtimeCursor] = [:]
  private var ackOrder: [String: [String: UInt64]] = [:]
  private var confirmedOrder: [String: UInt64] = [:]
  private var nextAckOrder: UInt64 = 0
  private var delivered: Set<String> = []
  private var deliveredOrder: [String] = []

  public init(
    configuration: ServiceConfiguration, userID: String,
    tokenProvider: @escaping AccessTokenProvider,
    cursorStore: any RealtimeCursorStore = MemoryRealtimeCursorStore(), autoReconnect: Bool = true,
    readyTimeout: Duration = .seconds(15),
    socketFactory: @escaping WebSocketFactory = { try URLSessionWebSocketConnection(url: $0) }
  ) throws {
    guard readyTimeout > .zero else {
      throw MMGTError.invalidConfiguration("Realtime timeout must be positive")
    }
    self.configuration = configuration
    identity = try AccountIdentity(configuration: configuration, userID: userID)
    self.tokenProvider = tokenProvider
    factory = socketFactory
    cursors = cursorStore
    self.autoReconnect = autoReconnect
    self.readyTimeout = readyTimeout
  }
  public func connectionStates() -> AsyncStream<RealtimeConnectionState> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<RealtimeConnectionState>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    stateObservers[id] = continuation
    continuation.yield(state)
    continuation.onTermination = { @Sendable _ in Task { await self.removeStateObserver(id) } }
    return stream
  }
  private func removeStateObserver(_ id: UUID) { stateObservers[id] = nil }
  public func messages() -> AsyncThrowingStream<RealtimeMessage, any Error> {
    let id = UUID()
    let (stream, continuation) = AsyncThrowingStream<RealtimeMessage, any Error>.makeStream(
      bufferingPolicy: .bufferingOldest(256))
    listeners[id] = continuation
    continuation.onTermination = { @Sendable _ in Task { await self.removeListener(id) } }
    return stream
  }
  private func removeListener(_ id: UUID) { listeners[id] = nil }
  private func emit(_ message: RealtimeMessage) {
    for (id, listener) in listeners {
      switch listener.yield(message) {
      case .dropped:
        listener.finish(throwing: MMGTError.bufferOverflow)
        listeners[id] = nil
      case .terminated: listeners[id] = nil
      default: break
      }
    }
  }
  public func connect() async throws {
    try Task.checkCancellation()
    guard !permanent else { throw MMGTError.sessionChanged }
    if state == .open { return }
    desired = true
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
          return
        }
        waiters[id] = continuation
        if worker == nil { start() }
      }
    } onCancel: {
      Task { await self.cancelConnect(id) }
    }
  }
  private func cancelConnect(_ id: UUID) async {
    if let waiter = waiters.removeValue(forKey: id) { waiter.resume(throwing: CancellationError()) }
    if waiters.isEmpty, state != .open { await disconnect() }
  }
  private func start() {
    backoff?.cancel()
    backoff = nil
    attempt = UUID()
    let expected = attempt
    delivered.removeAll()
    deliveredOrder.removeAll()
    state = retryCount == 0 ? .connecting : .reconnecting
    deadline = Task {
      do {
        try await Task.sleep(for: readyTimeout)
        await failed(MMGTError.connectionTimeout, expected: expected, retry: true)
      } catch {}
    }
    worker = Task {
      do {
        let token = try await tokenProvider()
        guard !Task.isCancelled, expected == attempt, desired else { return }
        guard !token.isEmpty else { throw MMGTError.unauthenticated }
        let connection = try factory(configuration.webSocketURL(["ws"]))
        socket = connection
        try await connection.send([
          "type": "auth", "app_id": .string(configuration.appID), "access_token": .string(token),
        ])
        while !Task.isCancelled {
          let wire = try await connection.receive()
          guard expected == attempt else { return }
          try await received(RealtimeMessage(wire: wire), expected: expected)
        }
      } catch {
        await failed(
          error, expected: expected,
          retry: !(error is CancellationError) && (error as? MMGTError) != .unauthenticated
            && (error as? MMGTError) != .sessionChanged)
      }
    }
  }
  private func received(_ message: RealtimeMessage, expected: UUID) async throws {
    guard expected == attempt else { return }
    if state != .open {
      switch message {
      case .ready, .error: break
      default: throw MMGTError.invalidResponse("Message arrived before Realtime ready")
      }
    }
    switch message {
    case .ready(let id, let userID):
      guard userID == identity.userID, state != .open else { throw MMGTError.sessionChanged }
      deadline?.cancel()
      deadline = nil
      state = .open
      connectionID = id
      retryCount = 0
      let waiting = Array(waiters.values)
      waiters.removeAll()
      for waiter in waiting { waiter.resume() }
      emit(message)
      for channel in subscriptions.keys.sorted() {
        try await sendSubscription(channel, expected: expected)
      }
      return
    case .error(let code, let message):
      if [
        "invalid_auth", "invalid_token", "auth_required", "invalid_app", "unauthorized",
        "forbidden",
      ].contains(code) {
        await failed(
          APIError(status: 401, code: code, message: message), expected: expected, retry: false)
        return
      }
    case .event(let event):
      guard subscriptions[event.channel] != nil else {
        throw MMGTError.invalidResponse("Event arrived for an unsubscribed channel")
      }
      let key = event.channel + "\0" + event.id
      if delivered.contains(key) { return }
      delivered.insert(key)
      deliveredOrder.append(key)
      if deliveredOrder.count > 4096 { delivered.remove(deliveredOrder.removeFirst()) }
    case .acknowledged(let channel, let eventID, _):
      if let order = ackOrder[channel]?[eventID], order > (confirmedOrder[channel] ?? 0),
        let current = cursorState[channel]
      {
        if let next = try await cursors.compareAndSet(
          identity: identity, channel: channel, expected: current, eventID: eventID)
        {
          guard expected == attempt else { return }
          cursorState[channel] = next
          confirmedOrder[channel] = order
          ackOrder[channel] = ackOrder[channel]?.filter { $0.value > order }
        } else {
          throw APIError(
            status: 409, code: "cursor_changed",
            message: "Another client advanced this Realtime cursor; reconnect to resume")
        }
      }
    case .replayGap(let channel, _):
      if let current = cursorState[channel] {
        let next = try await cursors.compareAndSet(
          identity: identity, channel: channel, expected: current, eventID: nil)
        guard expected == attempt else { return }
        if let next {
          cursorState[channel] = next
        } else {
          cursorState[channel] = try await cursors.load(identity: identity, channel: channel)
        }
      }
    default: break
    }
    guard expected == attempt else { return }
    emit(message)
  }
  private func failed(_ error: any Error, expected: UUID, retry: Bool) async {
    guard attempt == expected else { return }
    attempt = UUID()
    worker?.cancel()
    worker = nil
    deadline?.cancel()
    deadline = nil
    let connection = socket
    socket = nil
    connectionID = nil
    state = .closed
    let waiting = Array(waiters.values)
    waiters.removeAll()
    for waiter in waiting { waiter.resume(throwing: error) }
    if let api = error as? APIError {
      emit(.error(code: api.code, message: api.message))
    } else {
      emit(
        .error(
          code: retry ? "connection_closed" : "authentication_failed",
          message: "Realtime connection ended"))
    }
    if !retry { desired = false }
    if desired, autoReconnect, retry, !permanent {
      retryCount += 1
      let delay = min(30.0, pow(2.0, Double(min(retryCount - 1, 5)))) * Double.random(in: 0.8...1.2)
      backoff = Task {
        do {
          try await Task.sleep(for: .seconds(delay))
          if desired, !permanent { start() }
        } catch {}
      }
    }
    await connection?.close()
  }
  public func subscribe(_ subscription: RealtimeSubscription) async throws {
    guard !permanent else { throw MMGTError.sessionChanged }
    subscriptions[subscription.channel] = subscription
    if state == .open { try await sendSubscription(subscription.channel, expected: attempt) }
  }
  private func sendSubscription(_ channel: String, expected: UUID) async throws {
    guard let subscription = subscriptions[channel] else { return }
    let cursor = try await cursors.load(identity: identity, channel: channel)
    let grant = try await subscription.grantProvider?(channel)
    guard attempt == expected, subscriptions[channel] != nil else { throw MMGTError.sessionChanged }
    var body: [String: JSONValue] = [
      "type": "subscribe", "channel": .string(channel), "presence": .bool(subscription.presence),
      "ack_mode": "manual",
    ]
    if let grant { body["grant"] = .string(grant) }
    if let id = cursor.eventID { body["resume_after"] = .string(id) }
    cursorState[channel] = cursor
    ackOrder[channel] = [:]
    confirmedOrder[channel] = 0
    try await send(.object(body))
  }
  public func unsubscribe(_ channel: String) async throws {
    subscriptions[channel] = nil
    cursorState[channel] = nil
    ackOrder[channel] = nil
    confirmedOrder[channel] = nil
    if state == .open { try await send(["type": "unsubscribe", "channel": .string(channel)]) }
  }
  public func publish(channel: String, eventType: String, payload: JSONValue, grant: String)
    async throws
  {
    try RealtimeChannels.validate(channel)
    guard !grant.isEmpty, !eventType.isEmpty else {
      throw MMGTError.invalidConfiguration("Publishing requires a grant and event type")
    }
    try await send([
      "type": "publish", "channel": .string(channel), "event_type": .string(eventType),
      "payload": payload, "grant": .string(grant),
    ])
  }
  /// Transport acknowledgement only. Call after the application has accepted the event.
  public func acknowledge(_ event: RealtimeEvent) async throws {
    guard subscriptions[event.channel] != nil else {
      throw MMGTError.invalidConfiguration("Channel is not subscribed")
    }
    nextAckOrder += 1
    ackOrder[event.channel, default: [:]][event.id] = nextAckOrder
    try await send([
      "type": "ack", "channel": .string(event.channel), "event_id": .string(event.id),
    ])
  }
  private func send(_ message: JSONValue) async throws {
    guard state == .open, let socket else {
      throw MMGTError.invalidResponse("Realtime is not connected")
    }
    let expected = attempt
    try await socket.send(message)
    guard expected == attempt else { throw MMGTError.sessionChanged }
  }
  public func disconnect() async {
    resumeAfterBackground = false
    await stopConnection()
  }
  private func stopConnection() async {
    desired = false
    backoff?.cancel()
    backoff = nil
    await failed(CancellationError(), expected: attempt, retry: false)
  }
  public func close() async {
    permanent = true
    await disconnect()
    for listener in listeners.values { listener.finish() }
    listeners.removeAll()
  }
  public func activityChanged(_ activity: ApplicationActivity) async {
    switch activity {
    case .signedOut: await close()
    case .background:
      resumeAfterBackground = desired || resumeAfterBackground
      await stopConnection()
    case .active:
      let shouldResume = desired || resumeAfterBackground
      resumeAfterBackground = false
      if shouldResume, !permanent, state != .open { try? await connect() }
    case .inactive: break
    }
  }
}
