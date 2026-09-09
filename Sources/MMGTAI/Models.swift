// Derived from platform DTO declarations. Verification status and hashes: Contracts/platform.json.
import Foundation
import MMGTCore

public typealias AIProviderKind = String

public typealias AIReasoningEffort = String

public struct AIModelDescriptor: Codable, Sendable, Equatable {
  public var id: String
  public var connectionId: String
  public var displayName: String
  public var providerKind: AIProviderKind
  public var enabled: Bool
  public var discoveredAt: String
  public init(
    id: String, connectionId: String, displayName: String, providerKind: AIProviderKind,
    enabled: Bool, discoveredAt: String
  ) {
    self.id = id
    self.connectionId = connectionId
    self.displayName = displayName
    self.providerKind = providerKind
    self.enabled = enabled
    self.discoveredAt = discoveredAt
  }
  enum CodingKeys: String, CodingKey {
    case id = "id"
    case connectionId = "connectionId"
    case displayName = "displayName"
    case providerKind = "providerKind"
    case enabled = "enabled"
    case discoveredAt = "discoveredAt"
  }
}

public struct AICatalog: Codable, Sendable, Equatable {
  public var status: String
  public var models: [AIModelDescriptor]
  public init(status: String, models: [AIModelDescriptor]) {
    self.status = status
    self.models = models
  }
  enum CodingKeys: String, CodingKey {
    case status = "status"
    case models = "models"
  }
}

public struct AIInputItem: Codable, Sendable, Equatable {
  public var role: String
  public var content: [AIContentPart]
  public init(role: String, content: [AIContentPart]) {
    self.role = role
    self.content = content
  }
  enum CodingKeys: String, CodingKey {
    case role = "role"
    case content = "content"
  }
}

public struct AIToolDefinition: Codable, Sendable, Equatable {
  public var name: String
  public var `description`: String?
  public var parameters: JSONValue
  public var strict: Bool?
  public init(
    name: String, `description`: String? = nil, parameters: JSONValue, strict: Bool? = nil
  ) {
    self.name = name
    self.`description` = `description`
    self.parameters = parameters
    self.strict = strict
  }
  enum CodingKeys: String, CodingKey {
    case name = "name"
    case `description` = "description"
    case parameters = "parameters"
    case strict = "strict"
  }
}

public struct AIToolResult: Codable, Sendable, Equatable {
  public var callId: String
  public var output: JSONValue
  public var error: String?
  public init(callId: String, output: JSONValue, error: String? = nil) {
    self.callId = callId
    self.output = output
    self.error = error
  }
  enum CodingKeys: String, CodingKey {
    case callId = "callId"
    case output = "output"
    case error = "error"
  }
}

public struct AIResponseRequest: Codable, Sendable, Equatable {
  public var connectionId: String
  public var model: String
  public var systemPrompt: String?
  public var input: [AIInputItem]
  public var reasoningEffort: AIReasoningEffort?
  public var maxOutputTokens: Int?
  public var outputSchema: JSONValue?
  public var tools: [AIToolDefinition]?
  public var toolCalls: [AIToolCall]?
  public var toolResults: [AIToolResult]?
  public init(
    connectionId: String, model: String, systemPrompt: String? = nil, input: [AIInputItem],
    reasoningEffort: AIReasoningEffort? = nil, maxOutputTokens: Int? = nil,
    outputSchema: JSONValue? = nil, tools: [AIToolDefinition]? = nil,
    toolCalls: [AIToolCall]? = nil, toolResults: [AIToolResult]? = nil
  ) {
    self.connectionId = connectionId
    self.model = model
    self.systemPrompt = systemPrompt
    self.input = input
    self.reasoningEffort = reasoningEffort
    self.maxOutputTokens = maxOutputTokens
    self.outputSchema = outputSchema
    self.tools = tools
    self.toolCalls = toolCalls
    self.toolResults = toolResults
  }
  enum CodingKeys: String, CodingKey {
    case connectionId = "connectionId"
    case model = "model"
    case systemPrompt = "systemPrompt"
    case input = "input"
    case reasoningEffort = "reasoningEffort"
    case maxOutputTokens = "maxOutputTokens"
    case outputSchema = "outputSchema"
    case tools = "tools"
    case toolCalls = "toolCalls"
    case toolResults = "toolResults"
  }
}

public struct AIFileReference: Codable, Sendable, Equatable {
  public var id: String
  public var contentType: String
  public var sizeBytes: Int
  public var checksumSha256: String
  public var expiresAt: String
  public init(
    id: String, contentType: String, sizeBytes: Int, checksumSha256: String, expiresAt: String
  ) {
    self.id = id
    self.contentType = contentType
    self.sizeBytes = sizeBytes
    self.checksumSha256 = checksumSha256
    self.expiresAt = expiresAt
  }
  enum CodingKeys: String, CodingKey {
    case id = "id"
    case contentType = "contentType"
    case sizeBytes = "sizeBytes"
    case checksumSha256 = "checksumSha256"
    case expiresAt = "expiresAt"
  }
}

public struct AIToolCall: Codable, Sendable, Equatable {
  public var id: String
  public var name: String
  public var arguments: JSONValue
  public init(id: String, name: String, arguments: JSONValue) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }
  enum CodingKeys: String, CodingKey {
    case id = "id"
    case name = "name"
    case arguments = "arguments"
  }
}

public struct AIUsage: Codable, Sendable, Equatable {
  public var inputTokens: Int
  public var outputTokens: Int
  public var reasoningTokens: Int?
  public var totalTokens: Int
  public init(inputTokens: Int, outputTokens: Int, reasoningTokens: Int? = nil, totalTokens: Int) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.reasoningTokens = reasoningTokens
    self.totalTokens = totalTokens
  }
  enum CodingKeys: String, CodingKey {
    case inputTokens = "inputTokens"
    case outputTokens = "outputTokens"
    case reasoningTokens = "reasoningTokens"
    case totalTokens = "totalTokens"
  }
}

public struct AIResponse: Codable, Sendable, Equatable {
  public var id: String
  public var status: String
  public var provider: AIProviderKind
  public var model: String
  public var text: String?
  public var structuredOutput: JSONValue?
  public var toolCalls: [AIToolCall]?
  public var usage: AIUsage
  public var providerRequestId: String?
  public init(
    id: String, status: String, provider: AIProviderKind, model: String, text: String? = nil,
    structuredOutput: JSONValue? = nil, toolCalls: [AIToolCall]? = nil, usage: AIUsage,
    providerRequestId: String? = nil
  ) {
    self.id = id
    self.status = status
    self.provider = provider
    self.model = model
    self.text = text
    self.structuredOutput = structuredOutput
    self.toolCalls = toolCalls
    self.usage = usage
    self.providerRequestId = providerRequestId
  }
  enum CodingKeys: String, CodingKey {
    case id = "id"
    case status = "status"
    case provider = "provider"
    case model = "model"
    case text = "text"
    case structuredOutput = "structuredOutput"
    case toolCalls = "toolCalls"
    case usage = "usage"
    case providerRequestId = "providerRequestId"
  }
}

public struct AIErrorBody: Codable, Sendable, Equatable {
  public var code: String
  public var message: String
  public var retryable: Bool?
  public init(code: String, message: String, retryable: Bool? = nil) {
    self.code = code
    self.message = message
    self.retryable = retryable
  }
  enum CodingKeys: String, CodingKey {
    case code = "code"
    case message = "message"
    case retryable = "retryable"
  }
}
