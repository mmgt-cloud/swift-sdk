import Foundation
import MMGTCore

public enum ReplicaError: Error, Sendable, Equatable {
  case invalidIdentity, invalidRecord, staleRevision, closed, guestCannotSync
  case identityMismatch, collectionNotSupported, confirmationRequired, collision
  case importChanged, alreadyAdopted, differentStore, dependencyCycle, unresolvedDependency
  case useReplicaResolution, reconciliationRequired
}

public enum ReplicaPrincipal: Codable, Sendable, Hashable {
  case guest(String)
  case user(String)
  public var id: String {
    switch self {
    case .guest(let id), .user(let id): return id
    }
  }
  public var isGuest: Bool {
    if case .guest = self { return true }
    return false
  }
}

/// Guest partitions never masquerade as an AccountIdentity. User partitions reuse the existing store.
public struct ReplicaIdentity: Codable, Sendable, Hashable {
  public let configuration: ServiceConfiguration
  public let principal: ReplicaPrincipal
  public init(configuration: ServiceConfiguration, principal: ReplicaPrincipal) throws {
    guard !principal.id.isEmpty, !principal.id.contains(where: { $0.isWhitespace }),
      !principal.id.contains("\0")
    else { throw ReplicaError.invalidIdentity }
    self.configuration = configuration
    self.principal = principal
  }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      configuration: values.decode(ServiceConfiguration.self, forKey: .configuration),
      principal: values.decode(ReplicaPrincipal.self, forKey: .principal))
  }
  public var account: AccountIdentity? {
    guard !principal.isGuest else { return nil }
    return try? AccountIdentity(configuration: configuration, userID: principal.id)
  }
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.configuration.storagePartition == rhs.configuration.storagePartition
      && lhs.principal == rhs.principal
  }
  public func hash(into hasher: inout Hasher) {
    hasher.combine(configuration.storagePartition)
    hasher.combine(principal)
  }
}

public struct ReplicaRecordKey: Codable, Sendable, Hashable {
  public let collection: String
  public let id: String
  public init(collection: String, id: String) {
    self.collection = collection
    self.id = id
  }
}

public struct ReplicaRecord: Codable, Sendable, Equatable {
  public let key: ReplicaRecordKey
  public var data: JSONValue?
  public var deleted: Bool
  public var serverVersion: String?
  public var localRevision: String?
  public var pending: Bool
  public var issues: [SyncIssue]
}

public struct ReplicaIntent: Codable, Sendable, Equatable {
  public let key: ReplicaRecordKey
  public let data: JSONValue?
  public let deleted: Bool
  public init(key: ReplicaRecordKey, data: JSONValue?, deleted: Bool) {
    self.key = key
    self.data = data
    self.deleted = deleted
  }
}

/// Store implementation detail exposed for custom ReplicaLocalStore implementations.
public struct ReplicaJournalEntry: Codable, Sendable, Equatable {
  public let entry: OutboxEntry
  public let localRevision: String
  public let predecessor: String?
  public let dependencies: [String]
  public var state: String
  public var result: SyncPushResult?
  public init(
    entry: OutboxEntry, localRevision: String, predecessor: String? = nil,
    dependencies: [String] = [], state: String = "pending", result: SyncPushResult? = nil
  ) {
    self.entry = entry
    self.localRevision = localRevision
    self.predecessor = predecessor
    self.dependencies = dependencies
    self.state = state
    self.result = result
  }
}

public struct ReplicaMetadata: Codable, Sendable, Equatable {
  public let identity: ReplicaIdentity
  public var revision: String
  public let deliveryClientID: String
  public var adoptedImportID: String?
  public var journal: [ReplicaJournalEntry]
  public init(identity: ReplicaIdentity) {
    self.identity = identity
    revision = "0"
    deliveryClientID = UUID().uuidString
    journal = []
    adoptedImportID = nil
  }
}

public struct ReplicaStoreSnapshot: Codable, Sendable, Equatable {
  public var metadata: ReplicaMetadata
  public var confirmed: [SyncRecord]
  public var outbox: [OutboxEntry]
  public var issues: [SyncIssue]
  public init(
    metadata: ReplicaMetadata, confirmed: [SyncRecord], outbox: [OutboxEntry], issues: [SyncIssue]
  ) {
    self.metadata = metadata
    self.confirmed = confirmed
    self.outbox = outbox
    self.issues = issues
  }
  public var records: [ReplicaRecord] {
    var rows: [ReplicaRecordKey: ReplicaRecord] = [:]
    for record in confirmed where (record.workspaceId ?? "").isEmpty {
      let key = ReplicaRecordKey(collection: record.collection, id: record.id)
      rows[key] = .init(
        key: key, data: record.data, deleted: record.deleted,
        serverVersion: record.version, localRevision: nil, pending: false, issues: [])
    }
    func overlay(_ entry: OutboxEntry, revision: String?) {
      let m = entry.mutation
      guard (m.workspaceId ?? "").isEmpty else { return }
      let key = ReplicaRecordKey(collection: m.collection, id: m.recordId)
      var row =
        rows[key]
        ?? .init(
          key: key, data: nil, deleted: true, serverVersion: nil,
          localRevision: nil, pending: false, issues: [])
      row.data = m.data
      row.deleted = m.op == "delete"
      row.pending = true
      row.localRevision = revision ?? row.localRevision
      rows[key] = row
    }
    let managed = Set(metadata.journal.map { $0.entry.mutation.mutationId })
    for issue in issues where !managed.contains(issue.entry.mutation.mutationId) {
      overlay(issue.entry, revision: nil)
    }
    for entry in outbox where !managed.contains(entry.mutation.mutationId) {
      overlay(entry, revision: nil)
    }
    for item in metadata.journal {
      let key = ReplicaRecordKey(
        collection: item.entry.mutation.collection, id: item.entry.mutation.recordId)
      if item.state == "pending" {
        overlay(item.entry, revision: item.localRevision)
      } else if rows[key] != nil {
        rows[key]?.localRevision = item.localRevision
      }
    }
    for issue in issues {
      let key = ReplicaRecordKey(
        collection: issue.entry.mutation.collection, id: issue.entry.mutation.recordId)
      rows[key]?.issues.append(issue)
    }
    for entry in outbox where entry.needsReconciliation {
      let m = entry.mutation
      let key = ReplicaRecordKey(collection: m.collection, id: m.recordId)
      if !(rows[key]?.issues.contains { $0.entry.mutation.mutationId == m.mutationId } ?? false) {
        rows[key]?.issues.append(
          .init(
            entry: entry,
            result: .init(
              mutationId: m.mutationId,
              collection: m.collection, recordId: m.recordId, status: "rejected",
              error: "requires_reconciliation"), createdAt: entry.createdAt))
      }
    }
    return rows.values.sorted { ($0.key.collection, $0.key.id) < ($1.key.collection, $1.key.id) }
  }
}

public struct ReplicaImportItem: Codable, Sendable, Equatable {
  public let source: ReplicaRecord
  public let target: ReplicaRecord?
  public init(source: ReplicaRecord, target: ReplicaRecord?) {
    self.source = source
    self.target = target
  }
}
public struct ReplicaImportPlan: Codable, Sendable, Equatable {
  public let id: String
  public let source: ReplicaIdentity
  public let target: ReplicaIdentity
  public let sourceRevision: String
  public let targetRevision: String
  public let items: [ReplicaImportItem]
  public let requiresConfirmation: Bool
  public var committed: Bool
  public var mutationIDs: [String]
  public init(
    id: String = UUID().uuidString, source: ReplicaIdentity, target: ReplicaIdentity,
    sourceRevision: String, targetRevision: String, items: [ReplicaImportItem],
    requiresConfirmation: Bool
  ) {
    self.id = id
    self.source = source
    self.target = target
    self.sourceRevision = sourceRevision
    self.targetRevision = targetRevision
    self.items = items
    self.requiresConfirmation = requiresConfirmation
    committed = false
    mutationIDs = []
  }
}
public enum ReplicaImportAction: String, Codable, Sendable {
  case importRecord, replaceTarget, keepTarget
}
public struct ReplicaImportDecision: Codable, Sendable, Equatable {
  public let key: ReplicaRecordKey
  public let action: ReplicaImportAction
  public let data: JSONValue?
  public let dependencies: [ReplicaRecordKey]
  public init(
    key: ReplicaRecordKey, action: ReplicaImportAction, data: JSONValue? = nil,
    dependencies: [ReplicaRecordKey] = []
  ) {
    self.key = key
    self.action = action
    self.data = data
    self.dependencies = dependencies
  }
}
public struct ReplicaImportProgress: Sendable {
  public let plan: ReplicaImportPlan
  public let pending: Int
  public let applied: Int
  public let resolved: Int
  public let issues: [SyncIssue]
}

/// Optional extension. Existing SyncLocalStore implementations need no new methods.
/// All CAS operations include metadata, records, queue and issues in one durable transaction.
public protocol ReplicaLocalStore: SyncLocalStore, AnyObject {
  func replicaSnapshot(identity: ReplicaIdentity) async throws -> ReplicaStoreSnapshot
  func commitReplica(identity: ReplicaIdentity, expectedRevision: String, intents: [ReplicaIntent])
    async throws
  func prepareReplicaImport(_ plan: ReplicaImportPlan) async throws -> ReplicaImportPlan
  func replicaImport(id: String, source: ReplicaIdentity) async throws -> ReplicaImportPlan
  func commitReplicaImport(
    id: String, source: ReplicaIdentity, confirmed: Bool,
    decisions: [ReplicaImportDecision]
  ) async throws -> ReplicaImportPlan
  func resolveReplicaIssue(
    identity: ReplicaIdentity, expectedRevision: String, mutationID: String,
    replacement: ReplicaIntent?) async throws
}

public func validateReplicaIntent(_ intent: ReplicaIntent) throws {
  guard
    [intent.key.collection, intent.key.id].allSatisfy({
      !$0.isEmpty && !$0.contains("\0") && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }),
    intent.deleted || intent.data != nil,
    try JSONEncoder().encode(intent).count < 900_000
  else { throw ReplicaError.invalidRecord }
}
public func nextReplicaRevision(_ revision: String) throws -> String {
  guard let value = UInt64(revision), value < UInt64.max else { throw ReplicaError.staleRevision }
  return String(value + 1)
}
