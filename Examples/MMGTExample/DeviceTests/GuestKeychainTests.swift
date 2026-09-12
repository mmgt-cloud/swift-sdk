import Foundation
import Testing

@testable import MMGTAuth

/// Requires an application-hosted runner with a Keychain access-group identity.
@Suite(.timeLimit(.minutes(1))) struct GuestKeychainTests {
  @Test func realKeychainCASHasOneWinnerAndNoCrossPartitionChanges() async throws {
    let disk = KeychainGuestSessionStore()
    let partition = "synthetic-guest-test-" + UUID().uuidString
    defer { try? disk.removeTestPartition(partition) }
    let first = GuestStoredSession(phase: .active, renewalSecret: "synthetic-only-not-a-credential")
    #expect(try disk.compareAndSwap(partition: partition, expectedRevision: nil, next: first))
    let wins = try await withThrowingTaskGroup(of: Bool.self) { group in
      for _ in 0..<16 {
        group.addTask {
          try KeychainGuestSessionStore().compareAndSwap(
            partition: partition, expectedRevision: first.revision, next: .init(phase: .revoked))
        }
      }
      var count = 0
      for try await won in group { if won { count += 1 } }
      return count
    }
    #expect(wins == 1)
    #expect(try disk.load(partition: partition)?.phase == .revoked)
    #expect(try disk.load(partition: partition + "-other") == nil)
    #expect(try !disk.compareAndSwap(partition: partition, expectedRevision: nil, next: first))
  }
}
