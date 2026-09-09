import Foundation
import MMGTCore
import Observation

public enum AIStreamStatus: Sendable {
  case idle, streaming, completed, requiresAction, interrupted, failed
}

/// Keeps partial output explicitly incomplete on cancellation or transport loss. It never retries generation or runs tools.
@MainActor @Observable public final class AIState: ApplicationLifecycleParticipant {
  public let client: AIClient
  public private(set) var text = ""
  public private(set) var reasoning = ""
  public private(set) var response: AIResponse?
  public private(set) var status: AIStreamStatus = .idle
  public private(set) var error: (any Error)?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var pending: Task<Void, any Error>?
  @ObservationIgnored private let maximumBufferedBytes: Int
  @ObservationIgnored private var closed = false
  public init(client: AIClient, maximumBufferedBytes: Int = 1_048_576) throws {
    guard maximumBufferedBytes > 0 else {
      throw MMGTError.invalidConfiguration("AI output buffer must be positive")
    }
    self.client = client
    self.maximumBufferedBytes = maximumBufferedBytes
  }
  public func stream(_ request: AIResponseRequest) async throws {
    guard !closed else { throw MMGTError.sessionChanged }
    cancel()
    let expected = generation
    text = ""
    reasoning = ""
    response = nil
    error = nil
    status = .streaming
    let task = Task {
      let events = try await client.stream(request)
      for try await event in events {
        guard generation == expected else { throw MMGTError.sessionChanged }
        try Task.checkCancellation()
        switch event {
        case .textDelta(let value): try append(value, toReasoning: false)
        case .reasoningDelta(let value): try append(value, toReasoning: true)
        case .completed(let value):
          response = value
          status = .completed
        case .requiresAction(let value):
          response = value
          status = .requiresAction
        case .failed(let body): throw APIError(status: 0, code: body.code, message: body.message)
        default: break
        }
      }
      if status == .streaming { throw MMGTError.streamInterrupted }
    }
    pending = task
    defer { if generation == expected { pending = nil } }
    do {
      try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
    } catch {
      if generation == expected {
        self.error = error
        status = error is APIError ? .failed : .interrupted
      }
      throw error
    }
  }
  private func append(_ value: String, toReasoning: Bool) throws {
    guard text.utf8.count + reasoning.utf8.count + value.utf8.count <= maximumBufferedBytes else {
      throw MMGTError.bufferOverflow
    }
    if toReasoning { reasoning += value } else { text += value }
  }
  public func cancel() {
    generation = UUID()
    pending?.cancel()
    pending = nil
    if status == .streaming { status = .interrupted }
  }
  public func activityChanged(_ activity: ApplicationActivity) async {
    if activity == .background { cancel() }
    if activity == .signedOut {
      closed = true
      cancel()
      text = ""
      reasoning = ""
      response = nil
      error = nil
      status = .idle
    }
    await client.activityChanged(activity)
  }
}
