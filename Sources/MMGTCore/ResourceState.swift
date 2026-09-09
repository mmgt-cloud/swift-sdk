import Foundation
import Observation

/// Observable state for a cancellable request. Create a new instance when the account changes.
@MainActor @Observable
public final class ResourceState<Value: Sendable>: ApplicationLifecycleParticipant {
  public private(set) var value: Value?
  public private(set) var error: (any Error)?
  public private(set) var isLoading = false
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var pending: Task<Value, any Error>?
  @ObservationIgnored private var closed = false
  @ObservationIgnored private let operation: @Sendable () async throws -> Value
  public init(operation: @escaping @Sendable () async throws -> Value) {
    self.operation = operation
  }
  @discardableResult public func reload() async throws -> Value {
    guard !closed else { throw MMGTError.sessionChanged }
    cancel()
    let expected = generation
    isLoading = true
    error = nil
    let task = Task { try await operation() }
    pending = task
    defer {
      if generation == expected {
        pending = nil
        isLoading = false
      }
    }
    do {
      let output = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      guard generation == expected else { throw MMGTError.sessionChanged }
      try Task.checkCancellation()
      value = output
      return output
    } catch {
      if generation == expected, !(error is CancellationError) { self.error = error }
      throw error
    }
  }
  public func cancel() {
    generation = UUID()
    pending?.cancel()
    pending = nil
    isLoading = false
  }
  public func clear() {
    cancel()
    value = nil
    error = nil
  }
  public func activityChanged(_ activity: ApplicationActivity) async {
    switch activity {
    case .signedOut:
      closed = true
      clear()
    case .background: cancel()
    default: break
    }
  }
}
