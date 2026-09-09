import Foundation
import MMGTCore

public struct RealtimeEvent: Codable, Sendable, Equatable {
  public let id: String
  public let channel: String
  public let eventType: String
  public let payload: JSONValue
  public let sentAt: String
  enum CodingKeys: String, CodingKey {
    case id, channel, payload
    case eventType = "event_type"
    case sentAt = "sent_at"
  }
}

public struct RealtimePresenceUser: Codable, Sendable, Equatable {
  public let userID: String
  public let connectionCount: Int
  enum CodingKeys: String, CodingKey {
    case userID = "user_id"
    case connectionCount = "connection_count"
  }
}

public enum RealtimeMessage: Sendable, Equatable {
  case ready(connectionID: String, userID: String)
  case subscribed(channel: String)
  case unsubscribed(channel: String)
  case event(RealtimeEvent)
  case replayGap(channel: String, fromEventID: String)
  case acknowledged(channel: String, eventID: String, ackedAt: String)
  case presenceSnapshot(channel: String, users: [RealtimePresenceUser])
  case presenceJoined(channel: String, userID: String)
  case presenceLeft(channel: String, userID: String)
  case error(code: String, message: String)
  case unknown(JSONValue)

  public init(wire: JSONValue) throws {
    func string(_ key: String) throws -> String {
      guard let value = wire[key]?.string else {
        throw MMGTError.invalidResponse("Missing Realtime field: \(key)")
      }
      return value
    }
    switch wire["type"]?.string {
    case "ready":
      self = .ready(connectionID: try string("connection_id"), userID: try string("user_id"))
    case "subscribed": self = .subscribed(channel: try string("channel"))
    case "unsubscribed": self = .unsubscribed(channel: try string("channel"))
    case "event": self = .event(try wire.decode())
    case "replay_gap":
      self = .replayGap(channel: try string("channel"), fromEventID: try string("from_event_id"))
    case "ack_confirmed":
      self = .acknowledged(
        channel: try string("channel"), eventID: try string("event_id"),
        ackedAt: try string("acked_at"))
    case "presence_snapshot":
      guard let users = wire["users"] else {
        throw MMGTError.invalidResponse("Missing presence users")
      }
      self = .presenceSnapshot(channel: try string("channel"), users: try users.decode())
    case "presence_joined":
      self = .presenceJoined(channel: try string("channel"), userID: try string("user_id"))
    case "presence_left":
      self = .presenceLeft(channel: try string("channel"), userID: try string("user_id"))
    case "error": self = .error(code: try string("code"), message: try string("message"))
    default: self = .unknown(wire)
    }
  }
}

public enum RealtimeConnectionState: String, Sendable {
  case idle, connecting, open, reconnecting, closed
}
public typealias RealtimeGrantProvider = @Sendable (String) async throws -> String

public struct RealtimeSubscription: Sendable {
  public let channel: String
  public let presence: Bool
  public let grantProvider: RealtimeGrantProvider?
  public init(channel: String, presence: Bool = false, grantProvider: RealtimeGrantProvider? = nil)
    throws
  {
    try RealtimeChannels.validate(channel)
    self.channel = channel
    self.presence = presence
    self.grantProvider = grantProvider
  }
}
