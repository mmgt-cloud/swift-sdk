import Foundation
import MMGTCore

public enum AIContentPart: Codable, Sendable, Equatable {
  case text(String)
  case image(fileID: String)
  case file(fileID: String)
  enum CodingKeys: String, CodingKey { case type, text, fileId }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .type) {
    case "text": self = .text(try c.decode(String.self, forKey: .text))
    case "image": self = .image(fileID: try c.decode(String.self, forKey: .fileId))
    case "file": self = .file(fileID: try c.decode(String.self, forKey: .fileId))
    default: throw MMGTError.invalidResponse("Unsupported AI content part")
    }
  }
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .text(let value):
      try c.encode("text", forKey: .type)
      try c.encode(value, forKey: .text)
    case .image(let id):
      try c.encode("image", forKey: .type)
      try c.encode(id, forKey: .fileId)
    case .file(let id):
      try c.encode("file", forKey: .type)
      try c.encode(id, forKey: .fileId)
    }
  }
}

public enum AIStreamEvent: Sendable, Equatable {
  case started(requestID: String)
  case textDelta(String)
  case reasoningDelta(String)
  case toolCall(AIToolCall)
  case usage(AIUsage)
  case completed(AIResponse)
  case requiresAction(AIResponse)
  case failed(AIErrorBody)
  case unknown(JSONValue)

  public init(wire: JSONValue) throws {
    switch wire["type"]?.string {
    case "response.started": self = .started(requestID: wire["requestId"]?.string ?? "")
    case "output.text.delta": self = .textDelta(wire["delta"]?.string ?? "")
    case "output.reasoning_summary.delta": self = .reasoningDelta(wire["delta"]?.string ?? "")
    case "tool.call": self = .toolCall(try Self.require(wire, "toolCall").decode())
    case "response.usage": self = .usage(try Self.require(wire, "usage").decode())
    case "response.completed": self = .completed(try Self.require(wire, "response").decode())
    case "response.requires_action":
      self = .requiresAction(try Self.require(wire, "response").decode())
    case "response.error": self = .failed(try Self.require(wire, "error").decode())
    default: self = .unknown(wire)
    }
  }
  private static func require(_ wire: JSONValue, _ key: String) throws -> JSONValue {
    guard let value = wire[key] else {
      throw MMGTError.invalidResponse("Missing AI event field: \(key)")
    }
    return value
  }
}
