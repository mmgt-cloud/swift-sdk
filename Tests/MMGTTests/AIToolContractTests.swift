import Foundation
import MMGTAI
import MMGTCore
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1))) struct AIToolContractTests {
  private func action(_ calls: [AIToolCall]) throws -> JSONValue {
    [
      "type": "response.requires_action",
      "response": try .encoding(WebSocketTests().response(status: "requires_action", calls: calls)),
    ]
  }
  private func complete() throws -> JSONValue {
    ["type": "response.completed", "response": try .encoding(WebSocketTests().response())]
  }
  private func request() -> AIResponseRequest {
    var input = WebSocketTests().input()
    input.tools = [.init(name: "lookup", parameters: ["type": "object"])]
    return input
  }
  private func client(_ socket: TestSocket) throws -> AIClient {
    AIClient(
      configuration: try WebSocketTests().config("ai"), tokenProvider: { "synthetic-token" },
      socketFactory: { _ in socket })
  }
  private let call = AIToolCall(id: "synthetic-call", name: "lookup", arguments: ["enabled": false])

  @Test func oneAllowedToolRoundCanCompleteWithoutStartingAgain() async throws {
    let socket = TestSocket([["type": "authenticated"], try action([call]), try complete()])
    let sdk = try client(socket)
    let result = try await sdk.runTools(
      request(), tools: ["lookup": { _, _ in ["enabled": false, "empty": .null] }], maxIterations: 1)
    #expect(result.status == "completed")
    let sent = await socket.sent
    #expect(sent.map { $0["type"]?.string } == ["authenticate", "start", "tool_result"])
    #expect(
      sent[2] == [
        "type": "tool_result", "callId": "synthetic-call",
        "output": ["enabled": false, "empty": .null],
      ])
    let golden: JSONValue = try SharedWireContractTests().decode("ai-toolresult")
    #expect(golden == sent[2])
    #expect(await socket.isClosed)
  }

  @Test func iterationLimitStopsBeforeAnotherToolSideEffect() async throws {
    let next = AIToolCall(id: "next-call", name: "lookup", arguments: [:])
    let socket = TestSocket([["type": "authenticated"], try action([call]), try action([next])])
    let executions = Mutex(0)
    let sdk = try client(socket)
    do {
      _ = try await sdk.runTools(
        request(),
        tools: [
          "lookup": { _, _ in
            executions.withLock { $0 += 1 }
            return .null
          }
        ], maxIterations: 1)
      Issue.record("Expected iteration limit")
    } catch let error as APIError { #expect(error.code == "tool_loop_limit") }
    #expect(executions.withLock { $0 } == 1)
    #expect(await socket.sent.filter { $0["type"]?.string == "tool_result" }.count == 1)
    #expect(await socket.isClosed)
  }

  @Test(arguments: ["duplicate", "empty", "undeclared"])
  func invalidRoundCannotExecuteItsFirstTool(_ kind: String) async throws {
    let other = AIToolCall(
      id: kind == "duplicate" ? call.id : kind == "empty" ? "" : "other",
      name: kind == "undeclared" ? "not-declared" : "lookup", arguments: [:])
    let socket = TestSocket([["type": "authenticated"], try action([call, other])])
    let executions = Mutex(0)
    let sdk = try client(socket)
    await #expect(throws: MMGTError.self) {
      _ = try await sdk.runTools(
        request(),
        tools: [
          "lookup": { _, _ in
            executions.withLock { $0 += 1 }
            return .null
          }
        ])
    }
    #expect(executions.withLock { $0 } == 0)
    #expect(await socket.sent.filter { $0["type"]?.string == "tool_result" }.isEmpty)
    #expect(await socket.isClosed)
  }

  @Test func changedCallIDCannotRepeatAnAlreadyExecutedEffect() async throws {
    let changed = AIToolCall(id: call.id, name: "lookup", arguments: ["enabled": true])
    let socket = TestSocket([["type": "authenticated"], try action([call]), try action([changed])])
    let executions = Mutex(0)
    let sdk = try client(socket)
    await #expect(throws: MMGTError.self) {
      _ = try await sdk.runTools(
        request(),
        tools: [
          "lookup": { _, _ in
            executions.withLock { $0 += 1 }
            return .null
          }
        ])
    }
    #expect(executions.withLock { $0 } == 1)
    #expect(await socket.sent.filter { $0["type"]?.string == "tool_result" }.count == 1)
    #expect(await socket.isClosed)
  }

  @Test func cancellationDuringToolDoesNotSubmitLateOutput() async throws {
    let socket = TestSocket([["type": "authenticated"], try action([call])])
    let gate = TokenGate()
    let sdk = try client(socket)
    let operation = Task {
      try await sdk.runTools(request(), tools: ["lookup": { _, _ in .string(await gate.token()) }])
    }
    await gate.wait()
    operation.cancel()
    await gate.resolve()
    await #expect(throws: CancellationError.self) { _ = try await operation.value }
    #expect(await socket.sent.filter { $0["type"]?.string == "tool_result" }.isEmpty)
    #expect(await socket.isClosed)
  }

  @Test func accountChangeDoesNotSubmitLateToolOutput() async throws {
    let socket = TestSocket([["type": "authenticated"], try action([call])])
    let gate = TokenGate()
    let sdk = try client(socket)
    let operation = Task {
      try await sdk.runTools(request(), tools: ["lookup": { _, _ in .string(await gate.token()) }])
    }
    await gate.wait()
    await sdk.close()
    await gate.resolve()
    await #expect(throws: MMGTError.sessionChanged) { _ = try await operation.value }
    #expect(await socket.sent.filter { $0["type"]?.string == "tool_result" }.isEmpty)
  }

  @Test func streamCancellationPreservesPartialResultWithoutSuccess() async throws {
    let socket = TestSocket([
      ["type": "authenticated"], ["type": "output.text.delta", "delta": "partial"],
    ])
    let sdk = try client(socket)
    let stream = try await sdk.stream(WebSocketTests().input())
    var iterator = stream.makeAsyncIterator()
    #expect(try await iterator.next() == .textDelta("partial"))
    await socket.waitForReceiveCall(3)
    await sdk.cancelPending()
    await #expect(throws: CancellationError.self) { _ = try await iterator.next() }
    #expect(await socket.sent.filter { $0["type"]?.string == "start" }.count == 1)
    #expect(await socket.isClosed)
  }
}
