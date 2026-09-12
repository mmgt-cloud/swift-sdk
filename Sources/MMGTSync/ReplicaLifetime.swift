import Foundation
import Synchronization

/// Cancellation ownership extends through asynchronous store transactions, including both ends of import.
final class ReplicaLifetime: Sendable {
  private struct State: Sendable {
    var closed = false
    var tasks: [UUID: @Sendable () -> Void] = [:]
  }
  private let state = Mutex(State())
  private func register(_ id: UUID, cancel: @escaping @Sendable () -> Void) throws {
    try state.withLock { value in
      guard !value.closed else { throw ReplicaError.closed }
      value.tasks[id] = cancel
    }
  }
  private func remove(_ id: UUID) { state.withLock { $0.tasks[id] = nil } }
  func cancel(close: Bool = false) {
    let tasks = state.withLock { value in
      if close { value.closed = true }
      let tasks = Array(value.tasks.values)
      value.tasks.removeAll()
      return tasks
    }
    for cancel in tasks { cancel() }
  }
  static func run<T: Sendable>(
    _ owners: [ReplicaLifetime], operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    let gate = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let task = Task {
      var iterator = gate.stream.makeAsyncIterator()
      guard await iterator.next() != nil else { throw CancellationError() }
      try Task.checkCancellation()
      return try await operation()
    }
    let id = UUID()
    defer { for owner in owners { owner.remove(id) } }
    do { for owner in owners { try owner.register(id, cancel: { task.cancel() }) } } catch {
      gate.continuation.finish()
      task.cancel()
      throw error
    }
    gate.continuation.yield(())
    gate.continuation.finish()
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}
