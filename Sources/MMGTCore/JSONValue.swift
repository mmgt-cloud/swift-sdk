import Foundation

/// JSON without a floating-point conversion of integral values. Dates stay on the wire as strings.
public enum JSONValue: Sendable, Equatable, Codable {
  case null
  case bool(Bool)
  case integer(Int64)
  case unsigned(UInt64)
  case decimal(Decimal)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer()
    if value.decodeNil() {
      self = .null
    } else if let v = try? value.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? value.decode(Int64.self) {
      self = .integer(v)
    } else if let v = try? value.decode(UInt64.self) {
      self = .unsigned(v)
    } else if let v = try? value.decode(Decimal.self) {
      self = .decimal(v)
    } else if let v = try? value.decode(String.self) {
      self = .string(v)
    } else if let v = try? value.decode([JSONValue].self) {
      self = .array(v)
    } else {
      self = .object(try value.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var value = encoder.singleValueContainer()
    switch self {
    case .null: try value.encodeNil()
    case .bool(let v): try value.encode(v)
    case .integer(let v): try value.encode(v)
    case .unsigned(let v): try value.encode(v)
    case .decimal(let v): try value.encode(v)
    case .string(let v): try value.encode(v)
    case .array(let v): try value.encode(v)
    case .object(let v): try value.encode(v)
    }
  }

  public subscript(key: String) -> JSONValue? {
    guard case .object(let values) = self else { return nil }
    return values[key]
  }
  public var string: String? { if case .string(let value) = self { value } else { nil } }
  public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
  public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
    try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
  }
  public static func encoding<T: Encodable>(_ value: T) throws -> Self {
    try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
  }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
  ExpressibleByIntegerLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral,
  ExpressibleByNilLiteral
{
  public init(stringLiteral value: String) { self = .string(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(integerLiteral value: Int64) { self = .integer(value) }
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
  public init(nilLiteral: ()) { self = .null }
}
