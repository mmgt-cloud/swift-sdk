// Derived from platform DTO declarations. Verification status and hashes: Contracts/platform.json.
import Foundation
import MMGTCore

public typealias SyncVersion = String

public typealias SyncCollectionMode = String

public typealias SyncAccessScope = String

public typealias SyncConflictPolicy = String

public typealias SyncOperation = String

public typealias SyncStatus = String

public struct SyncCollection: Codable, Sendable, Equatable {
  public var key: String
  public var displayName: String
  public var mode: SyncCollectionMode
  public var accessScope: SyncAccessScope
  public var conflictPolicy: SyncConflictPolicy
  public var schema: JSONValue
  public var enabled: Bool
  public var createdAt: String
  public var updatedAt: String
  public init(
    key: String, displayName: String, mode: SyncCollectionMode, accessScope: SyncAccessScope,
    conflictPolicy: SyncConflictPolicy, schema: JSONValue, enabled: Bool, createdAt: String,
    updatedAt: String
  ) {
    self.key = key
    self.displayName = displayName
    self.mode = mode
    self.accessScope = accessScope
    self.conflictPolicy = conflictPolicy
    self.schema = schema
    self.enabled = enabled
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
  enum CodingKeys: String, CodingKey {
    case key = "key"
    case displayName = "display_name"
    case mode = "mode"
    case accessScope = "access_scope"
    case conflictPolicy = "conflict_policy"
    case schema = "schema"
    case enabled = "enabled"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }
}

public struct SyncRecord: Codable, Sendable, Equatable {
  public var collection: String
  public var id: String
  public var version: SyncVersion
  public var data: JSONValue?
  public var deleted: Bool
  public var workspaceId: String?
  public var updatedAt: String?
  public init(
    collection: String, id: String, version: SyncVersion, data: JSONValue? = nil, deleted: Bool,
    workspaceId: String? = nil, updatedAt: String? = nil
  ) {
    self.collection = collection
    self.id = id
    self.version = version
    self.data = data
    self.deleted = deleted
    self.workspaceId = workspaceId
    self.updatedAt = updatedAt
  }
  enum CodingKeys: String, CodingKey {
    case collection = "collection"
    case id = "id"
    case version = "version"
    case data = "data"
    case deleted = "deleted"
    case workspaceId = "workspace_id"
    case updatedAt = "updated_at"
  }
}

public struct SyncMutation: Codable, Sendable, Equatable {
  public var collection: String
  public var recordId: String
  public var op: SyncOperation
  public var data: JSONValue?
  public var mutationId: String?
  public var baseVersion: SyncVersion?
  public var workspaceId: String?
  public init(
    collection: String, recordId: String, op: SyncOperation, data: JSONValue? = nil,
    mutationId: String? = nil, baseVersion: SyncVersion? = nil, workspaceId: String? = nil
  ) {
    self.collection = collection
    self.recordId = recordId
    self.op = op
    self.data = data
    self.mutationId = mutationId
    self.baseVersion = baseVersion
    self.workspaceId = workspaceId
  }
  enum CodingKeys: String, CodingKey {
    case collection = "collection"
    case recordId = "recordId"
    case op = "op"
    case data = "data"
    case mutationId = "mutationId"
    case baseVersion = "baseVersion"
    case workspaceId = "workspaceId"
  }
}

public struct SyncMutationPayload: Codable, Sendable, Equatable {
  public var collection: String
  public var recordId: String
  public var op: SyncOperation
  public var data: JSONValue?
  public var mutationId: String
  public var baseVersion: SyncVersion?
  public var workspaceId: String?
  public init(
    collection: String, recordId: String, op: SyncOperation, data: JSONValue? = nil,
    mutationId: String, baseVersion: SyncVersion? = nil, workspaceId: String? = nil
  ) {
    self.collection = collection
    self.recordId = recordId
    self.op = op
    self.data = data
    self.mutationId = mutationId
    self.baseVersion = baseVersion
    self.workspaceId = workspaceId
  }
  enum CodingKeys: String, CodingKey {
    case collection = "collection"
    case recordId = "record_id"
    case op = "op"
    case data = "data"
    case mutationId = "mutation_id"
    case baseVersion = "base_version"
    case workspaceId = "workspace_id"
  }
}

public struct SyncPushRequest: Codable, Sendable, Equatable {
  public var clientId: String
  public var mutations: [SyncMutationPayload]
  public init(clientId: String, mutations: [SyncMutationPayload]) {
    self.clientId = clientId
    self.mutations = mutations
  }
  enum CodingKeys: String, CodingKey {
    case clientId = "client_id"
    case mutations = "mutations"
  }
}

public struct SyncPushResult: Codable, Sendable, Equatable {
  public var mutationId: String
  public var collection: String
  public var recordId: String
  public var status: String
  public var version: SyncVersion?
  public var conflictId: String?
  public var error: String?
  public init(
    mutationId: String, collection: String, recordId: String, status: String,
    version: SyncVersion? = nil, conflictId: String? = nil, error: String? = nil
  ) {
    self.mutationId = mutationId
    self.collection = collection
    self.recordId = recordId
    self.status = status
    self.version = version
    self.conflictId = conflictId
    self.error = error
  }
  enum CodingKeys: String, CodingKey {
    case mutationId = "mutation_id"
    case collection = "collection"
    case recordId = "record_id"
    case status = "status"
    case version = "version"
    case conflictId = "conflict_id"
    case error = "error"
  }
}

public struct SyncPushResponse: Codable, Sendable, Equatable {
  public var results: [SyncPushResult]
  public init(results: [SyncPushResult]) {
    self.results = results
  }
  enum CodingKeys: String, CodingKey {
    case results = "results"
  }
}

public struct SyncPullRequest: Codable, Sendable, Equatable {
  public var clientId: String?
  public var cursor: String?
  public var limit: Int?
  public var collections: [String]?
  public var workspaceIds: [String]?
  public init(
    clientId: String? = nil, cursor: String? = nil, limit: Int? = nil, collections: [String]? = nil,
    workspaceIds: [String]? = nil
  ) {
    self.clientId = clientId
    self.cursor = cursor
    self.limit = limit
    self.collections = collections
    self.workspaceIds = workspaceIds
  }
  enum CodingKeys: String, CodingKey {
    case clientId = "client_id"
    case cursor = "cursor"
    case limit = "limit"
    case collections = "collections"
    case workspaceIds = "workspace_ids"
  }
}

public struct SyncChange: Codable, Sendable, Equatable {
  public var sequence: SyncVersion
  public var collection: String
  public var recordId: String
  public var op: SyncOperation
  public var version: SyncVersion
  public var data: JSONValue?
  public var workspaceId: String?
  public var userId: String?
  public var createdAt: String
  public init(
    sequence: SyncVersion, collection: String, recordId: String, op: SyncOperation,
    version: SyncVersion, data: JSONValue? = nil, workspaceId: String? = nil, userId: String? = nil,
    createdAt: String
  ) {
    self.sequence = sequence
    self.collection = collection
    self.recordId = recordId
    self.op = op
    self.version = version
    self.data = data
    self.workspaceId = workspaceId
    self.userId = userId
    self.createdAt = createdAt
  }
  enum CodingKeys: String, CodingKey {
    case sequence = "sequence"
    case collection = "collection"
    case recordId = "record_id"
    case op = "op"
    case version = "version"
    case data = "data"
    case workspaceId = "workspace_id"
    case userId = "user_id"
    case createdAt = "created_at"
  }
}

public struct SyncPullResponse: Codable, Sendable, Equatable {
  public var changes: [SyncChange]
  public var nextCursor: String
  public var hasMore: Bool
  public init(changes: [SyncChange], nextCursor: String, hasMore: Bool) {
    self.changes = changes
    self.nextCursor = nextCursor
    self.hasMore = hasMore
  }
  enum CodingKeys: String, CodingKey {
    case changes = "changes"
    case nextCursor = "next_cursor"
    case hasMore = "has_more"
  }
}

public struct SyncSnapshotRequest: Codable, Sendable, Equatable {
  public var collections: [String]?
  public var workspaceIds: [String]?
  public var pageToken: String?
  public var limit: Int?
  public init(
    collections: [String]? = nil, workspaceIds: [String]? = nil, pageToken: String? = nil,
    limit: Int? = nil
  ) {
    self.collections = collections
    self.workspaceIds = workspaceIds
    self.pageToken = pageToken
    self.limit = limit
  }
  enum CodingKeys: String, CodingKey {
    case collections = "collections"
    case workspaceIds = "workspace_ids"
    case pageToken = "page_token"
    case limit = "limit"
  }
}

public struct SyncSnapshotResponse: Codable, Sendable, Equatable {
  public var records: [SyncChange]
  public var watermark: SyncVersion
  public var nextPage: String?
  public var cursor: String?
  public var hasMore: Bool
  public var expiresAt: String
  public init(
    records: [SyncChange], watermark: SyncVersion, nextPage: String? = nil, cursor: String? = nil,
    hasMore: Bool, expiresAt: String
  ) {
    self.records = records
    self.watermark = watermark
    self.nextPage = nextPage
    self.cursor = cursor
    self.hasMore = hasMore
    self.expiresAt = expiresAt
  }
  enum CodingKeys: String, CodingKey {
    case records = "records"
    case watermark = "watermark"
    case nextPage = "next_page"
    case cursor = "cursor"
    case hasMore = "has_more"
    case expiresAt = "expires_at"
  }
}

public struct SyncBootstrapResponse: Codable, Sendable, Equatable {
  public var collections: [SyncCollection]
  public var contractRevision: String
  public var serverTime: String
  public init(collections: [SyncCollection], contractRevision: String, serverTime: String) {
    self.collections = collections
    self.contractRevision = contractRevision
    self.serverTime = serverTime
  }
  enum CodingKeys: String, CodingKey {
    case collections = "collections"
    case contractRevision = "contract_revision"
    case serverTime = "server_time"
  }
}

public struct SyncConflict: Codable, Sendable, Equatable {
  public var id: String
  public var collection: String
  public var recordId: String
  public var mutationId: String
  public var clientId: String
  public var userId: String
  public var baseVersion: SyncVersion?
  public var currentVersion: SyncVersion
  public var attemptedData: JSONValue?
  public var status: String
  public var createdAt: String
  public init(
    id: String, collection: String, recordId: String, mutationId: String, clientId: String,
    userId: String, baseVersion: SyncVersion? = nil, currentVersion: SyncVersion,
    attemptedData: JSONValue? = nil, status: String, createdAt: String
  ) {
    self.id = id
    self.collection = collection
    self.recordId = recordId
    self.mutationId = mutationId
    self.clientId = clientId
    self.userId = userId
    self.baseVersion = baseVersion
    self.currentVersion = currentVersion
    self.attemptedData = attemptedData
    self.status = status
    self.createdAt = createdAt
  }
  enum CodingKeys: String, CodingKey {
    case id = "id"
    case collection = "collection"
    case recordId = "record_id"
    case mutationId = "mutation_id"
    case clientId = "client_id"
    case userId = "user_id"
    case baseVersion = "base_version"
    case currentVersion = "current_version"
    case attemptedData = "attempted_data"
    case status = "status"
    case createdAt = "created_at"
  }
}
