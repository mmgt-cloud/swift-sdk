import Foundation

/// Pass a separate configuration to every application/environment. No credentials belong here.
public struct ServiceConfiguration: Sendable, Hashable, Codable {
  public let baseURL: URL
  public let appID: String

  public init(baseURL: URL, appID: String) throws {
    guard baseURL.scheme == "https", baseURL.host != nil,
      baseURL.user == nil, baseURL.password == nil,
      baseURL.query == nil, baseURL.fragment == nil, !appID.isEmpty,
      !appID.contains(where: { $0.isWhitespace || $0.isNewline }), !appID.contains("\0")
    else {
      throw MMGTError.invalidConfiguration("An HTTPS service URL and nonempty app ID are required")
    }
    self.baseURL = baseURL
    self.appID = appID
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      baseURL: values.decode(URL.self, forKey: .baseURL),
      appID: values.decode(String.self, forKey: .appID))
  }

  /// Append path components, never interpolate an identifier into a URL path.
  public func url(_ components: [String], query: [URLQueryItem] = []) throws -> URL {
    guard
      components.allSatisfy({
        !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\\")
          && !$0.contains("\0")
      })
    else {
      throw MMGTError.invalidConfiguration("Invalid path component")
    }
    let result = components.reduce(baseURL) { $0.appendingPathComponent($1) }
    guard var parts = URLComponents(url: result, resolvingAgainstBaseURL: false) else {
      throw MMGTError.invalidConfiguration("Invalid service URL")
    }
    if !query.isEmpty { parts.queryItems = query }
    guard let url = parts.url else { throw MMGTError.invalidConfiguration("Invalid request URL") }
    return url
  }

  public var storagePartition: String {
    var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
    parts.host = parts.host?.lowercased()
    if parts.port == 443 { parts.port = nil }
    while parts.path.hasSuffix("/") { parts.path.removeLast() }
    return "\(parts.string!)|\(appID)"
  }
}

public typealias AccessTokenProvider = @Sendable () async throws -> String

public struct AccountIdentity: Sendable, Hashable, Codable {
  public let environment: String
  public let appID: String
  public let userID: String
  public init(configuration: ServiceConfiguration, userID: String) throws {
    guard !userID.isEmpty else { throw MMGTError.invalidConfiguration("A user ID is required") }
    environment = configuration.storagePartition
    appID = configuration.appID
    self.userID = userID
  }
}

public enum ApplicationActivity: Sendable { case active, inactive, background, signedOut }

/// Implemented by session-bound services. SwiftUI adapters do not depend on those services.
public protocol ApplicationLifecycleParticipant: Sendable {
  func activityChanged(_ activity: ApplicationActivity) async
}
