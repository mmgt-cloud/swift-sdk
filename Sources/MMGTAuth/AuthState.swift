import Foundation
import MMGTCore
import Observation

/// SwiftUI-independent session state. Observe with `.task { await state.observe() }`.
@MainActor @Observable public final class AuthState: ApplicationLifecycleParticipant {
  public let session: AuthSession
  public private(set) var snapshot: AuthSessionSnapshot?
  public private(set) var error: (any Error)?
  public private(set) var isWorking = false
  public private(set) var loginResult: LoginResult?
  @ObservationIgnored private var generation = UUID()
  public init(session: AuthSession) { self.session = session }
  public func observe() async {
    for await value in await session.snapshots() {
      if Task.isCancelled { return }
      snapshot = value
    }
  }
  public func restore() async throws {
    try await perform { try await self.session.restore() }
  }
  @discardableResult public func authenticate(
    _ operation: @escaping @Sendable (AuthClient) async throws -> LoginResult
  ) async throws -> LoginResult {
    let result = try await perform { try await self.session.authenticate(operation) }
    loginResult = result
    return result
  }

  public func logout() async throws {
    // Clear UI immediately; remote revocation may fail without restoring local state.
    generation = UUID()
    loginResult = nil
    snapshot = nil
    try await perform { try await self.session.logout() }
  }
  private func perform<T>(_ operation: () async throws -> T) async throws -> T {
    generation = UUID()
    let expected = generation
    isWorking = true
    error = nil
    defer { if generation == expected { isWorking = false } }
    do {
      let output = try await operation()
      guard expected == generation else { throw MMGTError.sessionChanged }
      let next = await session.snapshot
      guard expected == generation else { throw MMGTError.sessionChanged }
      snapshot = next
      return output
    } catch {
      let next = await session.snapshot
      if expected == generation {
        self.error = error
        snapshot = next
      }
      throw error
    }
  }
  public func activityChanged(_ activity: ApplicationActivity) async {
    if activity == .signedOut {
      generation = UUID()
      loginResult = nil
      snapshot = nil
      isWorking = false
    }
    await session.activityChanged(activity)
  }
}
