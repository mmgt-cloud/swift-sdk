import Foundation

public struct APIError: Error, Sendable, Equatable {
  public let status: Int
  public let code: String
  public let message: String
  public let requestID: String?
  public let retryAfter: String?
  public let body: JSONValue?
  public init(
    status: Int, code: String, message: String, requestID: String? = nil, retryAfter: String? = nil,
    body: JSONValue? = nil
  ) {
    self.status = status
    self.code = code
    self.message = message
    self.requestID = requestID
    self.retryAfter = retryAfter
    self.body = body
  }
}

public enum MMGTError: Error, Sendable, Equatable {
  case invalidConfiguration(String)
  case invalidResponse(String)
  case unauthenticated
  case sessionChanged
  case streamInterrupted
  case bufferOverflow
  case connectionTimeout
  case unsupported(String)
}

public struct HTTPResponse: Sendable {
  public let data: Data
  public let status: Int
  public let headers: [String: String]
  public init(data: Data, status: Int, headers: [String: String] = [:]) {
    self.data = data
    self.status = status
    self.headers = Dictionary(
      headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
  }
}

public protocol HTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// Refuse redirects, including same-origin redirects, to avoid replaying credential-bearing writes.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

public final class URLSessionTransport: HTTPTransport, Sendable {
  private let session: URLSession
  public init() {
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
  }
  public func send(_ request: URLRequest) async throws -> HTTPResponse {
    do {
      let (data, response) = try await session.data(for: request)
      try Task.checkCancellation()
      guard let http = response as? HTTPURLResponse else {
        throw MMGTError.invalidResponse("Expected HTTP response")
      }
      let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
        if let key = pair.key as? String { result[key] = String(describing: pair.value) }
      }
      return HTTPResponse(data: data, status: http.statusCode, headers: headers)
    } catch is CancellationError { throw CancellationError() } catch let error as URLError
      where error.code == .cancelled
    { throw CancellationError() }
  }
}

public struct HTTPClient: Sendable {
  public let configuration: ServiceConfiguration
  private let transport: any HTTPTransport
  private let tokenProvider: AccessTokenProvider?

  public init(
    configuration: ServiceConfiguration, tokenProvider: AccessTokenProvider? = nil,
    transport: any HTTPTransport = URLSessionTransport()
  ) {
    self.configuration = configuration
    self.tokenProvider = tokenProvider
    self.transport = transport
  }

  public func request<T: Decodable & Sendable>(
    _ type: T.Type = T.self, path: [String], method: String = "GET",
    body: JSONValue? = nil, query: [URLQueryItem] = [], authenticated: Bool = true,
    headers: [String: String] = [:]
  ) async throws -> T {
    let data = try await send(
      path: path, method: method, data: body.map { try JSONEncoder().encode($0) }, query: query,
      authenticated: authenticated, headers: headers)
    do { return try JSONDecoder().decode(type, from: data.isEmpty ? Data("{}".utf8) : data) } catch
    { throw MMGTError.invalidResponse("Response did not match \(T.self)") }
  }

  public func send(
    path: [String], method: String = "GET", data: Data? = nil,
    contentType: String = "application/json", query: [URLQueryItem] = [],
    authenticated: Bool = true, headers: [String: String] = [:]
  ) async throws -> Data {
    try Task.checkCancellation()
    var request = URLRequest(url: try configuration.url(path, query: query))
    request.httpMethod = method
    request.httpBody = data
    request.timeoutInterval = 60
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if data != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
    for (key, value) in headers {
      guard !["authorization", "x-app-id", "host", "cookie"].contains(key.lowercased()),
        !key.contains("\r"), !key.contains("\n"), !value.contains("\r"), !value.contains("\n")
      else {
        throw MMGTError.invalidConfiguration("A reserved or invalid HTTP header was supplied")
      }
      request.setValue(value, forHTTPHeaderField: key)
    }
    request.setValue(configuration.appID, forHTTPHeaderField: "X-App-ID")
    if authenticated {
      guard let token = try await tokenProvider?(), !token.isEmpty else {
        throw MMGTError.unauthenticated
      }
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    try Task.checkCancellation()
    let response = try await transport.send(request)
    try Task.checkCancellation()
    guard (200..<300).contains(response.status) else {
      let body = try? JSONDecoder().decode(JSONValue.self, from: response.data)
      let detail = body?["error"]
      throw APIError(
        status: response.status,
        code: detail?["code"]?.string ?? body?["code"]?.string ?? detail?.string ?? "http_error",
        message: detail?["message"]?.string ?? body?["message"]?.string ?? detail?.string
          ?? "Request failed",
        requestID: response.headers["x-request-id"], retryAfter: response.headers["retry-after"],
        body: body)
    }
    return response.data
  }
}
