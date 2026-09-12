import Foundation
import MMGTAuth
import MMGTCore
import MMGTSync
import MMGTSyncSQLite
import Network
import Synchronization
import Testing

private struct OfflineFailure: Error { let reason: String }
private let offlineProcess = UUID().uuidString
private func requireOffline(_ value: Bool, _ reason: String) throws {
  guard value else { throw OfflineFailure(reason: reason) }
}

private struct OfflineConfiguration: Codable {
  let environment, appID, foreignAppID, runID, phase: String
  static func load() throws -> Self {
    guard let encoded = ProcessInfo.processInfo.environment["MMGT_OFFLINE_CONFIGURATION"],
      let data = Data(base64Encoded: encoded), data.count < 8_192,
      let c = try? JSONDecoder().decode(Self.self, from: data),
      ["stage", "prod"].contains(c.environment), ["seed", "restart"].contains(c.phase),
      [c.appID, c.foreignAppID, c.runID].allSatisfy({ UUID(uuidString: $0) != nil }),
      c.appID != c.foreignAppID
    else { throw OfflineFailure(reason: "Explicit isolated offline configuration is required") }
    return c
  }
  var host: String { environment == "stage" ? "api.stage.mmgt.cloud" : "api.mmgt.cloud" }
}

private final class OfflinePath: Sendable {
  private let monitor = NWPathMonitor()
  private let status = Mutex<NWPath.Status?>(nil)
  init() {
    monitor.pathUpdateHandler = { [self] path in status.withLock { $0 = path.status } }
    monitor.start(queue: DispatchQueue(label: "cloud.mmgt.offline-acceptance"))
  }
  func requireDisconnected() async throws {
    for _ in 0..<100 {
      if let value = status.withLock({ $0 }) {
        try requireOffline(
          value == .unsatisfied, "iOS still has a network path; disable Wi-Fi and cellular data")
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw OfflineFailure(reason: "iOS network-path observation timed out")
  }
  func close() {
    monitor.cancel()
    monitor.pathUpdateHandler = nil
  }
}

/// This is a tracing wrapper around the real transport, never a mock response.
private actor OfflineHTTPTrace: HTTPTransport {
  private var count = 0
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    count += 1
    return try await URLSessionTransport().send(request)
  }
  func requests() -> Int { count }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct OfflineGuestTests {
  @Test func disconnectedFirstStartAndSeparateProcessRestart() async throws {
    let c = try OfflineConfiguration.load()
    let path = OfflinePath()
    defer { path.close() }
    try await path.requireDisconnected()
    let directory = URL.applicationSupportDirectory.appending(path: "GuestOffline/\(c.runID)")
    let marker = directory.appending(path: "seed.json")
    let completed = directory.appending(path: "completed")
    let database = directory.appending(path: "replica.sqlite")
    let process = offlineProcess
    if c.phase == "seed" {
      try requireOffline(
        !FileManager.default.fileExists(atPath: directory.path),
        "This first-start attempt already exists")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } else {
      try requireOffline(
        FileManager.default.fileExists(atPath: marker.path),
        "No durable seed from the earlier process")
      try requireOffline(
        !FileManager.default.fileExists(atPath: completed.path),
        "This restart attempt already finished")
    }
    let store = try SQLiteSyncStore(fileURL: database)
    let otherHost = c.environment == "stage" ? "api.mmgt.cloud" : "api.stage.mmgt.cloud"
    let profiles: [ReplicaPrincipal] = [
      .guest(c.runID), .guest(c.appID), .user(c.runID), .user(c.appID),
    ]
    let identities = try [c.host, otherHost].flatMap { host in
      try [c.appID, c.foreignAppID].flatMap { app in
        try profiles.map { principal in
          try ReplicaIdentity(
            configuration: .init(baseURL: URL(string: "https://\(host)/sync")!, appID: app),
            principal: principal)
        }
      }
    }
    let trace = OfflineHTTPTrace()
    let guest = try GuestSession(
      configuration: .init(baseURL: URL(string: "https://\(c.host)/auth")!, appID: c.appID),
      profileID: c.runID, transport: trace)
    try requireOffline(
      try await guest.summary().status == .local, "Offline profile created a technical AI session")
    let seed: [ReplicaStoreSnapshot]
    if c.phase == "restart" {
      let prior = try JSONDecoder().decode(Seed.self, from: Data(contentsOf: marker))
      try requireOffline(
        prior.process != process && prior.runID == c.runID, "Restart provenance differs")
      seed = prior.snapshots
      try requireOffline(seed.count == identities.count, "Incomplete durable seed")
    } else {
      seed = []
    }

    var snapshots: [ReplicaStoreSnapshot] = []
    for (index, identity) in identities.enumerated() {
      let replica = try LocalReplica(identity: identity, collections: ["notes"], store: store)
      if c.phase == "seed" {
        try requireOffline(
          try await replica.list(collection: "notes").isEmpty,
          "A different identity leaked into the fresh profile")
        let title = "Offline partition \(index)"
        try await replica.transaction { tx in
          try tx.upsert(collection: "notes", id: "same-record", data: ["title": .string(title)])
          try tx.upsert(
            collection: "notes", id: "delete-after-restart", data: ["title": "Temporary"])
        }
        let state = try await replica.snapshot()
        try requireOffline(
          state.metadata.journal.count == 2
            && state.outbox.count == (identity.principal.isGuest ? 0 : 2),
          "Atomic local journal/account queue differs")
        try requireOffline(
          state.records.allSatisfy { $0.serverVersion == nil && $0.localRevision != nil },
          "Local changes pretended to have server versions")
        snapshots.append(state)
      } else {
        let state = try await replica.snapshot()
        try requireOffline(
          state == seed[index],
          "Process restart changed the original journal, delivery IDs or partition")
        try requireOffline(
          try await replica.get(collection: "notes", id: "same-record")?.data?["title"]
            == .string("Offline partition \(index)"),
          "Same record ID leaked across app/environment/profile/kind")
        var changes = await replica.changes().makeAsyncIterator()
        _ = try await changes.next()
        try await replica.transaction { tx in
          try tx.upsert(collection: "notes", id: "same-record", data: ["title": "Updated offline"])
          try tx.delete(collection: "notes", id: "delete-after-restart")
        }
        guard let changed = try await changes.next() else {
          throw OfflineFailure(reason: "Observation ended before the local commit")
        }
        try requireOffline(
          changed.metadata.revision != state.metadata.revision,
          "Observation missed the committed revision")
        try requireOffline(
          try await replica.list(collection: "notes").count == 1, "Offline delete was not visible")
        let reopened = try LocalReplica(
          identity: identity, collections: ["notes"], store: SQLiteSyncStore(fileURL: database))
        try requireOffline(
          try await reopened.get(collection: "notes", id: "same-record")?.data?["title"]
            == "Updated offline", "Updated value was not durable")
        try requireOffline(
          try await reopened.get(collection: "notes", id: "delete-after-restart") == nil,
          "Deleted value reappeared after reopen")
        await reopened.close()
      }
      await replica.close()
    }
    try await path.requireDisconnected()
    try requireOffline(await trace.requests() == 0, "Local operations made an Auth/Sync request")
    try requireOffline(
      try await guest.summary().status == .local,
      "Local profile unexpectedly acquired cloud credentials")
    await guest.close()
    if c.phase == "seed" {
      try JSONEncoder().encode(Seed(process: process, runID: c.runID, snapshots: snapshots))
        .write(to: marker, options: [.atomic, .completeFileProtection])
    } else {
      try Data(process.utf8).write(to: completed, options: .withoutOverwriting)
    }
  }
  private struct Seed: Codable {
    let process, runID: String
    let snapshots: [ReplicaStoreSnapshot]
  }
}
