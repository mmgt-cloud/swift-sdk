import CryptoKit
import Foundation
import MMGTAI
import MMGTCore
import MMGTSync

/// Example-owned domain rules shared by the UI and tools, not an SDK conversation service.
struct PersonalDomain: Sendable {
  enum Kind: String, CaseIterable, Sendable {
    case list, task, note
    var collection: String {
      switch self {
      case .list: "personal_lists"
      case .task: "personal_tasks"
      case .note: "personal_notes"
      }
    }
  }
  static let collections = [
    "personal_lists", "personal_tasks", "personal_notes", "personal_chat_messages",
  ]
  let replica: LocalReplica
  static func stamp() -> String { Date().ISO8601Format() }
  static func validate(_ intent: ReplicaIntent) throws {
    guard collections.contains(intent.key.collection) else {
      throw ReplicaError.collectionNotSupported
    }
    if intent.deleted { return }
    guard case .object(let value) = intent.data else { throw ReplicaError.invalidRecord }
    var keys: Set<String> = ["createdAt", "updatedAt"]
    for field in keys {
      guard let text = value[field]?.string,
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)) != nil
          || (try? Date.ISO8601FormatStyle().parse(text)) != nil
      else { throw ReplicaError.invalidRecord }
    }
    if intent.key.collection == "personal_chat_messages" {
      keys.formUnion(["conversationId", "role", "text", "status"])
      guard let conversation = value["conversationId"]?.string, !conversation.isEmpty,
        ["user", "assistant"].contains(value["role"]?.string ?? ""),
        ["pending", "completed", "interrupted"].contains(value["status"]?.string ?? ""),
        let text = value["text"]?.string, text.utf16.count <= 40_000
      else { throw ReplicaError.invalidRecord }
    } else {
      keys.insert("title")
      guard let title = value["title"]?.string, !title.isEmpty,
        title.utf16.count <= (intent.key.collection == "personal_tasks" ? 240 : 120)
      else { throw ReplicaError.invalidRecord }
      if intent.key.collection != "personal_lists" {
        keys.insert("listId")
        guard value["listId"] == .null || !(value["listId"]?.string ?? "").isEmpty else {
          throw ReplicaError.invalidRecord
        }
      }
      if intent.key.collection == "personal_tasks" {
        keys.insert("completed")
        guard value["completed"]?.bool != nil else { throw ReplicaError.invalidRecord }
      }
      if intent.key.collection == "personal_notes" {
        keys.insert("body")
        guard let text = value["body"]?.string, text.utf16.count <= 20_000 else {
          throw ReplicaError.invalidRecord
        }
      }
    }
    guard Set(value.keys) == keys else { throw ReplicaError.invalidRecord }
  }
  @discardableResult func create(
    kind: Kind, title: String, body: String = "", listID: String? = nil,
    id: String = UUID().uuidString
  ) async throws -> String {
    try Task.checkCancellation()
    let now = Self.stamp()
    var data: [String: JSONValue] = [
      "title": .string(title), "createdAt": .string(now), "updatedAt": .string(now),
    ]
    if kind != .list { data["listId"] = listID.map(JSONValue.string) ?? .null }
    if kind == .task { data["completed"] = false }
    if kind == .note { data["body"] = .string(body) }
    let value = JSONValue.object(data)
    try await replica.transaction { tx in
      try Task.checkCancellation()
      if let listID, tx.get(collection: "personal_lists", id: listID) == nil {
        throw MMGTError.invalidConfiguration("The selected list no longer exists")
      }
      if let existing = tx.get(collection: kind.collection, id: id) {
        guard existing.data?["title"] == value["title"], existing.data?["body"] == value["body"],
          existing.data?["listId"] == value["listId"]
        else {
          throw MMGTError.invalidConfiguration(
            "This tool identifier already belongs to another item")
        }
        return
      }
      try tx.upsert(collection: kind.collection, id: id, data: value)
    }
    return id
  }
  func edit(kind: Kind, id: String, title: String, body: String = "") async throws {
    try Task.checkCancellation()
    try await replica.transaction { tx in
      guard case .object(var data) = tx.get(collection: kind.collection, id: id)?.data else {
        throw ReplicaError.invalidRecord
      }
      data["title"] = .string(title)
      data["updatedAt"] = .string(Self.stamp())
      if kind == .note { data["body"] = .string(body) }
      try tx.upsert(collection: kind.collection, id: id, data: .object(data))
    }
  }
  func complete(id: String, completed: Bool) async throws {
    try Task.checkCancellation()
    try await replica.transaction { tx in
      guard case .object(var data) = tx.get(collection: "personal_tasks", id: id)?.data else {
        throw ReplicaError.invalidRecord
      }
      data["completed"] = .bool(completed)
      data["updatedAt"] = .string(Self.stamp())
      try tx.upsert(collection: "personal_tasks", id: id, data: .object(data))
    }
  }
  func remove(kind: Kind, id: String) async throws {
    try Task.checkCancellation()
    try await replica.transaction { tx in
      guard tx.get(collection: kind.collection, id: id) != nil else {
        throw ReplicaError.invalidRecord
      }
      if kind == .list {
        for collection in ["personal_tasks", "personal_notes"] {
          for row in tx.list(collection: collection) where row.data?["listId"]?.string == id {
            guard case .object(var value) = row.data else { throw ReplicaError.invalidRecord }
            value["listId"] = .null
            value["updatedAt"] = .string(Self.stamp())
            try tx.upsert(collection: collection, id: row.key.id, data: .object(value))
          }
        }
      }
      try tx.delete(collection: kind.collection, id: id)
    }
  }
  static func importDecisions(
    _ plan: ReplicaImportPlan, choices: [ReplicaRecordKey: ReplicaImportAction]
  ) throws -> [ReplicaImportDecision] {
    try plan.items.map { item in
      let key = item.source.key
      let action: ReplicaImportAction
      if item.target != nil {
        guard let choice = choices[key], choice == .keepTarget || choice == .replaceTarget else {
          throw MMGTError.invalidConfiguration("Choose how to resolve every ID collision")
        }
        action = choice
      } else {
        action = .importRecord
      }
      var dependencies: [ReplicaRecordKey] = []
      if action != .keepTarget, let listID = item.source.data?["listId"]?.string {
        let parent = ReplicaRecordKey(collection: "personal_lists", id: listID)
        if plan.items.contains(where: { $0.source.key == parent }) {
          dependencies = [parent]
        } else {
          throw MMGTError.invalidConfiguration("Import contains a missing personal list")
        }
      }
      return .init(key: key, action: action, dependencies: dependencies)
    }
  }
  static let toolDefinitions: [AIToolDefinition] = [
    .init(
      name: "read_personal_data",
      description: "Read a bounded page of local lists, tasks and notes; chat history is excluded.",
      parameters: [
        "type": "object",
        "properties": [
          "collection": [
            "type": "string", "enum": ["personal_lists", "personal_tasks", "personal_notes"],
          ], "offset": ["type": "integer", "minimum": 0],
          "limit": ["type": "integer", "minimum": 1, "maximum": 20],
        ], "additionalProperties": false,
      ]),
    .init(
      name: "create_personal_item", description: "Create an item after the person confirms it.",
      parameters: [
        "type": "object",
        "properties": [
          "kind": ["type": "string", "enum": ["list", "task", "note"]], "title": ["type": "string"],
          "body": ["type": "string"], "listId": ["type": ["string", "null"]],
        ], "required": ["kind", "title"], "additionalProperties": false,
      ]),
    .init(
      name: "set_personal_task_completed",
      description: "Change task completion after confirmation.",
      parameters: [
        "type": "object",
        "properties": ["id": ["type": "string"], "completed": ["type": "boolean"]],
        "required": ["id", "completed"], "additionalProperties": false,
      ]),
    .init(
      name: "delete_personal_item",
      description: "Delete an item after confirmation. Deleting a list detaches its children.",
      parameters: [
        "type": "object",
        "properties": [
          "kind": ["type": "string", "enum": ["list", "task", "note"]], "id": ["type": "string"],
        ], "required": ["kind", "id"], "additionalProperties": false,
      ]),
  ]
  func tools(requestID: String, confirm: @escaping @Sendable (String) async -> Bool)
    -> AIToolRegistry
  {
    [
      "read_personal_data": { value, _ in
        let data = try Self.arguments(value, keys: ["collection", "offset", "limit"])
        let offset = try data["offset"]?.decode(Int.self) ?? 0
        let limit = try data["limit"]?.decode(Int.self) ?? 20
        guard offset >= 0, (1...20).contains(limit) else { throw ReplicaError.invalidRecord }
        let collection = try data["collection"]?.decode(String.self)
        if let collection, !Self.collections.dropLast().contains(collection) {
          throw ReplicaError.collectionNotSupported
        }
        let rows = try await replica.snapshot().records.filter {
          !$0.deleted && $0.key.collection != "personal_chat_messages"
            && (collection == nil || $0.key.collection == collection)
        }
        let page = rows.dropFirst(offset).prefix(limit).map { row -> JSONValue in
          [
            "collection": .string(row.key.collection), "id": .string(row.key.id),
            "data": row.data ?? .null,
          ]
        }
        let end = min(rows.count, offset + limit)
        return [
          "items": .array(Array(page)), "total": .integer(Int64(rows.count)),
          "nextOffset": end < rows.count ? .integer(Int64(end)) : .null,
        ]
      },
      "create_personal_item": { value, call in
        let data = try Self.arguments(value, keys: ["kind", "title", "body", "listId"])
        guard let kind = Kind(rawValue: data["kind"]?.string ?? ""),
          let title = data["title"]?.string
        else { throw ReplicaError.invalidRecord }
        let body = try data["body"]?.decode(String.self) ?? ""
        let listID = data["listId"] == .null ? nil : try data["listId"]?.decode(String.self)
        guard await confirm("Create \(kind.rawValue): \(title)") else {
          throw MMGTError.invalidConfiguration("The local change was declined")
        }
        try Task.checkCancellation()
        let id = SHA256.hash(data: try JSONEncoder().encode([requestID, call.id])).map {
          String(format: "%02x", $0)
        }.joined()
        _ = try await create(kind: kind, title: title, body: body, listID: listID, id: id)
        return ["id": .string(id), "savedLocally": true]
      },
      "set_personal_task_completed": { value, _ in
        let data = try Self.arguments(value, keys: ["id", "completed"])
        guard let id = data["id"]?.string, let done = data["completed"]?.bool else {
          throw ReplicaError.invalidRecord
        }
        guard await confirm("Set task \(id) to \(done ? "complete" : "incomplete")") else {
          throw MMGTError.invalidConfiguration("The local change was declined")
        }
        try Task.checkCancellation()
        try await complete(id: id, completed: done)
        return ["savedLocally": true]
      },
      "delete_personal_item": { value, _ in
        let data = try Self.arguments(value, keys: ["kind", "id"])
        guard let kind = Kind(rawValue: data["kind"]?.string ?? ""), let id = data["id"]?.string
        else { throw ReplicaError.invalidRecord }
        guard await confirm("Delete \(kind.rawValue) \(id)") else {
          throw MMGTError.invalidConfiguration("The local change was declined")
        }
        try Task.checkCancellation()
        try await remove(kind: kind, id: id)
        return ["savedLocally": true]
      },
    ]
  }
  private static func arguments(_ value: JSONValue, keys: Set<String>) throws -> [String: JSONValue]
  {
    guard case .object(let data) = value, Set(data.keys).isSubset(of: keys) else {
      throw ReplicaError.invalidRecord
    }
    return data
  }
}
