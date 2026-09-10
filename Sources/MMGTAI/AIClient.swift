import Foundation
import MMGTCore

public typealias AIToolHandler = @Sendable (JSONValue, AIToolCall) async throws -> JSONValue
public typealias AIToolRegistry = [String: AIToolHandler]

/// Generation is never retried. A tool loop retains the same WebSocket until its terminal result.
public actor AIClient: ApplicationLifecycleParticipant {
  public nonisolated let configuration: ServiceConfiguration
  private let http: HTTPClient
  private let tokenProvider: AccessTokenProvider
  private let socketFactory: WebSocketFactory
  private var generation = UUID()
  private var requests: [UUID: @Sendable () -> Void] = [:]
  private var closed = false
  private var sockets: [UUID: any WebSocketConnection] = [:]
  private var tasks: [UUID: Task<Void, Never>] = [:]

  public init(
    configuration: ServiceConfiguration, tokenProvider: @escaping AccessTokenProvider,
    transport: any HTTPTransport = URLSessionTransport(),
    socketFactory: @escaping WebSocketFactory = { try URLSessionWebSocketConnection(url: $0) }
  ) {
    self.configuration = configuration
    self.tokenProvider = tokenProvider
    self.socketFactory = socketFactory
    http = HTTPClient(
      configuration: configuration, tokenProvider: tokenProvider, transport: transport)
  }
  private func check(_ expected: UUID? = nil) throws {
    try Task.checkCancellation()
    guard !closed, expected == nil || expected == generation else { throw MMGTError.sessionChanged }
  }
  private func path(_ parts: [String]) -> [String] { ["app", configuration.appID] + parts }
  private func request<T: Sendable>(_ operation: @escaping @Sendable (HTTPClient) async throws -> T)
    async throws -> T
  {
    try check()
    let expected = generation
    let id = UUID()
    let http = http
    let task = Task { try await operation(http) }
    requests[id] = { task.cancel() }
    defer { requests[id] = nil }
    do {
      let result = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      try check(expected)
      return result
    } catch {
      try check(expected)
      throw error
    }
  }
  public func catalog() async throws -> AICatalog {
    let endpoint = path(["catalog"])
    return try await request { try await $0.request(path: endpoint) }
  }
  public func generate(_ input: AIResponseRequest) async throws -> AIResponse {
    try validate(input)
    let endpoint = path(["responses"])
    let body = try JSONValue.encoding(input)
    return try await request { try await $0.request(path: endpoint, method: "POST", body: body) }
  }
  public func upload(data: Data, filename: String, contentType: String) async throws
    -> AIFileReference
  {
    try check()
    guard !filename.isEmpty, !filename.contains(where: { "\r\n\"\\".contains($0) }),
      !contentType.isEmpty, !contentType.contains(where: { "\r\n".contains($0) })
    else { throw MMGTError.invalidConfiguration("Invalid upload metadata") }
    let boundary = "mmgt-\(UUID())"
    var dataBody = Data(
      "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n"
        .utf8)
    dataBody.append(data)
    dataBody.append(Data("\r\n--\(boundary)--\r\n".utf8))
    let body = dataBody
    let endpoint = path(["files"])
    return try await request {
      let response = try await $0.send(
        path: endpoint, method: "POST", data: body,
        contentType: "multipart/form-data; boundary=\(boundary)")
      return try JSONDecoder().decode(AIFileReference.self, from: response)
    }
  }
  public func deleteFile(_ fileID: String) async throws {
    let endpoint = path(["files", fileID])
    let _: Data = try await request { try await $0.send(path: endpoint, method: "DELETE") }
  }
  private func validate(_ input: AIResponseRequest) throws {
    try check()
    guard !input.connectionId.isEmpty, !input.model.isEmpty else {
      throw MMGTError.invalidConfiguration("Choose an explicit AI connection and model")
    }
  }
  public func stream(_ input: AIResponseRequest) throws -> AsyncThrowingStream<
    AIStreamEvent, any Error
  > {
    try validate(input)
    let id = UUID()
    let expected = generation
    let (stream, continuation) = AsyncThrowingStream<AIStreamEvent, any Error>.makeStream(
      bufferingPolicy: .bufferingOldest(256))
    let task = Task {
      defer {
        tasks[id] = nil
        sockets[id] = nil
      }
      do {
        let socket = try socketFactory(configuration.webSocketURL(path(["stream"])))
        sockets[id] = socket
        do {
          try await authenticate(socket, expected: expected)
          let heartbeat = heartbeat(socket)
          defer { heartbeat.cancel() }
          try await socket.send(["type": "start", "request": try .encoding(input)])
          var terminal = false
          while !terminal {
            let wire = try await socket.receive()
            try check(expected)
            if wire["type"]?.string == "heartbeat" { continue }
            let event = try AIStreamEvent(wire: wire)
            switch continuation.yield(event) {
            case .dropped: throw MMGTError.bufferOverflow
            case .terminated: throw CancellationError()
            case .enqueued: break
            @unknown default: throw MMGTError.bufferOverflow
            }
            switch event {
            case .completed, .requiresAction, .failed: terminal = true
            default: break
            }
          }
          continuation.finish()
          await socket.close()
        } catch {
          await socket.close()
          try check(expected)
          throw error
        }
      } catch is CancellationError { continuation.finish(throwing: CancellationError()) } catch let
        error as MMGTError
      { continuation.finish(throwing: error) } catch let error as APIError {
        continuation.finish(throwing: error)
      } catch { continuation.finish(throwing: MMGTError.streamInterrupted) }
    }
    tasks[id] = task
    continuation.onTermination = { @Sendable _ in
      task.cancel()
      Task { await self.cancelStream(id) }
    }
    return stream
  }
  private func authenticate(_ socket: any WebSocketConnection, expected: UUID) async throws {
    let token = try await tokenProvider()
    try check(expected)
    guard !token.isEmpty else { throw MMGTError.unauthenticated }
    try await socket.send(["type": "authenticate", "token": .string(token)])
    while true {
      let wire = try await socket.receive()
      try check(expected)
      if wire["type"]?.string == "heartbeat" { continue }
      if wire["type"]?.string == "authenticated" { return }
      if wire["type"]?.string == "response.error", let error = wire["error"] {
        let body: AIErrorBody = try error.decode()
        throw APIError(status: 0, code: body.code, message: body.message)
      }
      throw MMGTError.invalidResponse("Expected AI authentication acknowledgement")
    }
  }
  private func heartbeat(_ socket: any WebSocketConnection) -> Task<Void, Never> {
    Task {
      do {
        while !Task.isCancelled {
          try await Task.sleep(for: .seconds(20))
          try Task.checkCancellation()
          try await socket.send(["type": "heartbeat"])
        }
      } catch { await socket.close() }
    }
  }
  public func runTools(_ input: AIResponseRequest, tools: AIToolRegistry, maxIterations: Int = 8)
    async throws -> AIResponse
  {
    try validate(input)
    guard (1...100).contains(maxIterations) else {
      throw MMGTError.invalidConfiguration("Tool iterations must be between 1 and 100")
    }
    let id = UUID()
    let expected = generation
    let socket = try socketFactory(configuration.webSocketURL(path(["stream"])))
    sockets[id] = socket
    defer { sockets[id] = nil }
    return try await withTaskCancellationHandler {
      do {
        try await authenticate(socket, expected: expected)
        let heartbeat = heartbeat(socket)
        defer { heartbeat.cancel() }
        // The server owns the accumulated request. A second start while it is
        // waiting for tools is rejected; return each result on this same socket.
        try await socket.send(["type": "start", "request": try .encoding(input)])
        var executed: [String: (call: AIToolCall, result: AIToolResult)] = [:]
        var iterations = 0
        while true {
          try check(expected)
          let response = try await terminalResponse(socket, expected: expected)
          if response.status == "completed" {
            await socket.close()
            return response
          }
          guard response.status == "requires_action", let calls = response.toolCalls, !calls.isEmpty
          else { throw MMGTError.invalidResponse("Expected AI tool calls") }
          guard iterations < maxIterations else {
            throw APIError(
              status: 409, code: "tool_loop_limit",
              message: "AI tool loop reached its iteration limit")
          }
          iterations += 1
          var callIDs = Set<String>()
          for call in calls {
            guard !call.id.isEmpty, callIDs.insert(call.id).inserted else {
              throw MMGTError.invalidResponse("AI returned empty or duplicate tool call IDs")
            }
            if let previous = executed[call.id], previous.call != call {
              throw MMGTError.invalidResponse("AI reused a tool call ID with different arguments")
            }
            guard tools[call.name] != nil,
              input.tools?.contains(where: { $0.name == call.name }) == true
            else {
              throw MMGTError.unsupported("AI requested an unregistered tool: \(call.name)")
            }
          }
          var results: [AIToolResult] = []
          for call in calls {
            try check(expected)
            if let previous = executed[call.id] {
              guard previous.call == call else {
                throw MMGTError.invalidResponse("AI reused a tool call ID with different arguments")
              }
              results.append(previous.result)
              continue
            }
            guard let handler = tools[call.name],
              input.tools?.contains(where: { $0.name == call.name }) == true
            else {
              throw MMGTError.unsupported("AI requested an unregistered tool: \(call.name)")
            }
            let output = try await handler(call.arguments, call)
            try check(expected)
            let result = AIToolResult(callId: call.id, output: output)
            executed[call.id] = (call, result)
            results.append(result)
          }
          for result in results {
            try check(expected)
            try await socket.send([
              "type": "tool_result", "callId": .string(result.callId), "output": result.output,
            ])
          }
        }
      } catch {
        await socket.close()
        try check(expected)
        throw error
      }
    } onCancel: {
      Task { await socket.close() }
    }
  }
  private func terminalResponse(_ socket: any WebSocketConnection, expected: UUID) async throws
    -> AIResponse
  {
    while true {
      let wire = try await socket.receive()
      try check(expected)
      switch try AIStreamEvent(wire: wire) {
      case .completed(let value), .requiresAction(let value): return value
      case .failed(let value): throw APIError(status: 0, code: value.code, message: value.message)
      default: continue
      }
    }
  }
  private func cancelStream(_ id: UUID) async {
    tasks[id]?.cancel()
    tasks[id] = nil
    if let socket = sockets.removeValue(forKey: id) { await socket.close() }
  }
  public func cancelPending() async {
    generation = UUID()
    for cancel in requests.values { cancel() }
    requests.removeAll()
    for task in tasks.values { task.cancel() }
    tasks.removeAll()
    let current = Array(sockets.values)
    sockets.removeAll()
    for socket in current { await socket.close() }
  }
  public func close() async {
    closed = true
    await cancelPending()
  }
  public func activityChanged(_ activity: ApplicationActivity) async {
    if case .signedOut = activity {
      await close()
    } else if case .background = activity {
      await cancelPending()
    }
  }
}
