import Foundation
import MMGTCore

public enum SyncStoreError: Error, Sendable, Equatable {
  case invalidScope
  case invalidVersion
  case staleFeed
  case invalidChange
  case mutationIDReused
  case mutationAlreadyAttempted
  case invalidSettlement
  case issueNotFound
}

public struct SyncScope: Codable, Sendable, Hashable {
  public let collections: [String]
  public let workspaceIDs: [String]
  public init(collections: [String] = [], workspaceIDs: [String] = []) throws {
    guard
      (collections + workspaceIDs).allSatisfy({
        !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
          && !$0.contains("\0")
      }), workspaceIDs.isEmpty || !collections.isEmpty
    else { throw SyncStoreError.invalidScope }
    self.collections = Array(Set(collections)).sorted()
    self.workspaceIDs = Array(Set(workspaceIDs)).sorted()
  }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      collections: c.decode([String].self, forKey: .collections),
      workspaceIDs: c.decode([String].self, forKey: .workspaceIDs))
  }
  public func contains(collection: String, workspaceID: String?) -> Bool {
    (collections.isEmpty || collections.contains(collection))
      && ((workspaceID ?? "").isEmpty || workspaceIDs.contains(workspaceID!))
  }
}

public enum SyncVersions {
  public static func validate(_ value: String) throws {
    guard !value.isEmpty, value == "0" || value.first != "0",
      value.utf8.allSatisfy({ (48...57).contains($0) }), let number = UInt64(value),
      number <= UInt64(Int64.max)
    else { throw SyncStoreError.invalidVersion }
  }
  public static func less(_ lhs: String, than rhs: String) throws -> Bool {
    try validate(lhs)
    try validate(rhs)
    return lhs.count == rhs.count ? lhs < rhs : lhs.count < rhs.count
  }
}

public struct SnapshotProgress: Codable, Sendable, Equatable {
  public var nextPage: String
  public var watermark: String
  public var expiresAt: String
  public init(nextPage: String, watermark: String, expiresAt: String) {
    self.nextPage = nextPage
    self.watermark = watermark
    self.expiresAt = expiresAt
  }
}

public struct SyncFeedState: Codable, Sendable, Equatable {
  public var revision: String
  public var cursor: String?
  public var snapshot: SnapshotProgress?
  public init(revision: String = "0", cursor: String? = nil, snapshot: SnapshotProgress? = nil) {
    self.revision = revision
    self.cursor = cursor
    self.snapshot = snapshot
  }
}

public struct OutboxEntry: Codable, Sendable, Equatable {
  public var mutation: SyncMutationPayload
  public let deliveryClientID: String
  public let createdAt: Date
  public var attempted: Bool
  public var needsReconciliation: Bool
  public init(
    mutation: SyncMutationPayload, deliveryClientID: String, createdAt: Date = Date(),
    attempted: Bool = false, needsReconciliation: Bool = false
  ) {
    self.mutation = mutation
    self.deliveryClientID = deliveryClientID
    self.createdAt = createdAt
    self.attempted = attempted
    self.needsReconciliation = needsReconciliation
  }
}

public struct SyncIssue: Codable, Sendable, Equatable {
  public let entry: OutboxEntry
  public let result: SyncPushResult
  public let createdAt: Date
  public init(entry: OutboxEntry, result: SyncPushResult, createdAt: Date = Date()) {
    self.entry = entry
    self.result = result
    self.createdAt = createdAt
  }
}

/// Every write is atomic across store instances sharing a database; success means the transaction committed.
public protocol SyncLocalStore: Sendable {
  func feed(identity: AccountIdentity, scope: SyncScope) async throws -> SyncFeedState
  func commitPage(
    identity: AccountIdentity, scope: SyncScope, expectedRevision: String, page: SyncPullResponse
  ) async throws -> Bool
  func commitSnapshotPage(
    identity: AccountIdentity, scope: SyncScope, expectedRevision: String,
    page: SyncSnapshotResponse
  ) async throws -> Bool
  func resetFeed(
    identity: AccountIdentity, scope: SyncScope, expectedRevision: String, reconcile: Bool
  ) async throws -> Bool
  func addOutbox(identity: AccountIdentity, entries: [OutboxEntry]) async throws
  func replaceRecordMutation(identity: AccountIdentity, entry: OutboxEntry) async throws
  func outbox(identity: AccountIdentity) async throws -> [OutboxEntry]
  func preparePush(identity: AccountIdentity, mutationIDs: [String]) async throws -> [OutboxEntry]
  func settlePush(identity: AccountIdentity, sent: [OutboxEntry], results: [SyncPushResult])
    async throws
  func removeOutbox(identity: AccountIdentity, mutationIDs: [String]) async throws
  func issues(identity: AccountIdentity) async throws -> [SyncIssue]
  func removeIssues(identity: AccountIdentity, mutationIDs: [String]) async throws
  func resolveIssue(identity: AccountIdentity, mutationID: String, replacement: OutboxEntry)
    async throws
  func records(identity: AccountIdentity, collection: String) async throws -> [SyncRecord]
  func record(identity: AccountIdentity, collection: String, id: String) async throws -> SyncRecord?
}

public typealias SyncGrantProvider = @Sendable (SyncScope) async throws -> String

public struct SyncRunResult: Sendable, Equatable {
  public var pushed = 0
  public var pulled = 0
  public var conflicts = 0
  public var rejected = 0
  public var cursor: String?
  public var hasMore = false
  public var rebuilding = false
  public init() {}
}

public func validateSyncChange(_ change: SyncChange, identity: AccountIdentity, scope: SyncScope)
  throws
{
  try SyncVersions.validate(change.version)
  try SyncVersions.validate(change.sequence)
  guard !change.collection.isEmpty, !change.recordId.isEmpty,
    ["upsert", "delete"].contains(change.op),
    scope.contains(collection: change.collection, workspaceID: change.workspaceId),
    !(change.workspaceId ?? "").isEmpty || change.userId == identity.userID
  else { throw SyncStoreError.invalidChange }
  guard (try? WireDate.parse(change.createdAt)) != nil else { throw SyncStoreError.invalidChange }
}
