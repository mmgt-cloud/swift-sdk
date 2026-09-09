import Foundation
import MMGTCore
import Testing
import UIKit

@testable import MMGTAuth

@MainActor @Suite(.timeLimit(.minutes(1))) struct BrowserPresentationTests {
  @Test func waitsForCredentialSheetToReleaseTheScene() async throws {
    var state = BrowserPresentationGate.State.waiting
    var turns = 0
    var presented = false
    try await BrowserPresentationGate.wait(
      state: { state }, isCurrent: { true }, deadlineReached: { false },
      pause: {
        #expect(!presented)
        turns += 1
        if turns == 3 { state = .ready }
      })
    presented = true
    #expect(turns == 3 && presented)
  }

  @Test func activeSceneDoesNotDelayPresentation() async throws {
    try await BrowserPresentationGate.wait(
      state: { .ready }, isCurrent: { true }, deadlineReached: { false },
      pause: { Issue.record("An active scene should not wait") })
  }

  @Test func explicitCancellationWinsOverLaterActivation() async throws {
    var current = true
    var state = BrowserPresentationGate.State.waiting
    await #expect(throws: CancellationError.self) {
      try await BrowserPresentationGate.wait(
        state: { state }, isCurrent: { current }, deadlineReached: { false },
        pause: {
          current = false
          state = .ready
        })
    }
  }

  @Test func taskCancellationInterruptsWaiting() async throws {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    let task = Task {
      try await BrowserPresentationGate.wait(
        state: { .waiting }, isCurrent: { true }, deadlineReached: { false },
        pause: {
          continuation.yield(())
          try await Task.sleep(for: .seconds(30))
        })
    }
    for await _ in stream { break }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    continuation.finish()
  }

  @Test func timeoutAndSceneDisconnectionStopPresentation() async throws {
    for disconnected in [false, true] {
      var state = BrowserPresentationGate.State.waiting
      var expired = false
      var turns = 0
      await #expect(throws: MMGTError.self) {
        try await BrowserPresentationGate.wait(
          state: { state }, isCurrent: { true }, deadlineReached: { expired },
          pause: {
            turns += 1
            if disconnected { state = .unavailable } else { expired = true }
          })
      }
      #expect(turns == 1)
    }
  }

  @Test func detachedWindowCannotPresent() async throws {
    let window = UIWindow()
    window.windowScene = nil
    await #expect(throws: MMGTError.self) {
      try await BrowserPresentationGate.wait(for: window, isCurrent: { true })
    }
  }
}
