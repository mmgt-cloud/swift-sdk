import Foundation
import MMGTCore
import UIKit

/// Credential callbacks can arrive before iOS finishes reactivating the app's scene.
@MainActor
enum BrowserPresentationGate {
  enum State { case ready, waiting, unavailable }

  static func wait(for window: UIWindow, isCurrent: () -> Bool) async throws {
    guard let scene = window.windowScene else {
      throw MMGTError.invalidConfiguration("The presentation window has no connected scene")
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    try await wait(
      state: {
        guard window.windowScene === scene, scene.activationState != .unattached else {
          return .unavailable
        }
        return scene.activationState == .foregroundActive && !window.isHidden
          ? .ready : .waiting
      },
      isCurrent: isCurrent,
      deadlineReached: { clock.now >= deadline },
      pause: { try await clock.sleep(for: .milliseconds(50)) })
  }

  // Separate UIKit observation and the clock so transitions and cancellation can
  // be tested deterministically without presenting a real authentication sheet.
  static func wait(
    state: () -> State, isCurrent: () -> Bool,
    deadlineReached: () -> Bool, pause: () async throws -> Void
  ) async throws {
    while true {
      try Task.checkCancellation()
      guard isCurrent() else { throw CancellationError() }
      switch state() {
      case .ready: return
      case .unavailable:
        throw MMGTError.invalidConfiguration("The presentation scene is no longer connected")
      case .waiting: break
      }
      guard !deadlineReached() else {
        throw MMGTError.invalidConfiguration(
          "The presentation scene did not become active within 10 seconds")
      }
      try await pause()
    }
  }
}
