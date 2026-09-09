import Foundation
import MMGTAuth
import MMGTBilling
import MMGTCore
import Testing

actor RecordingTransport: HTTPTransport {
  private(set) var requests: [URLRequest] = []
  var responses: [HTTPResponse]
  init(_ responses: [HTTPResponse]) { self.responses = responses }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.append(request)
    guard !responses.isEmpty else { throw MMGTError.invalidResponse("Unexpected request") }
    return responses.removeFirst()
  }
}

@Suite struct CoreTests {
  @Test func losslessIntegersAndNull() throws {
    let source = Data(
      #"{"sequence":9007199254740993,"version":"9223372036854775807","clear":null,"enabled":false}"#
        .utf8)
    let json = try JSONDecoder().decode(JSONValue.self, from: source)
    #expect(json["sequence"] == .integer(9_007_199_254_740_993))
    #expect(json["version"] == .string("9223372036854775807"))
    #expect(json["clear"] == .null)
    #expect(json["missing"] == nil)
    #expect(json["enabled"] == .bool(false))
    #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(json)) == json)
  }
  @Test func configurationIsolationAndPathSafety() throws {
    let stage = try ServiceConfiguration(
      baseURL: URL(string: "https://stage.example/auth/")!, appID: "app-a")
    let prod = try ServiceConfiguration(
      baseURL: URL(string: "https://example/auth")!, appID: "app-a")
    #expect(stage.storagePartition != prod.storagePartition)
    #expect(
      try stage.url(["profile", "hello?#there"]).absoluteString
        == "https://stage.example/auth/profile/hello%3F%23there")
    #expect(throws: MMGTError.self) { try stage.url(["..", "admin"]) }
    #expect(throws: MMGTError.self) {
      try ServiceConfiguration(baseURL: URL(string: "http://example/auth")!, appID: "a")
    }
  }
  @Test func bodyBooleansAndBillingKeys() throws {
    let request = WorkspaceCheckoutRequest(offerId: "offer", workspaceName: "Team", extraSeats: 0)
    let json = try JSONValue.encoding(request)
    #expect(json["offer_id"] == .string("offer"))
    #expect(json["workspace_name"] == .string("Team"))
    #expect(json["extra_seats"] == .integer(0))
    #expect(json["success_url"] == nil)
    #expect(
      try JSONValue.encoding(TwoFALoginRequest(tempToken: "temp", rememberDevice: false))[
        "remember_device"] == .bool(false))
  }
  @Test func errorsPreserveDetailsAndNeverRetry() async throws {
    let transport = RecordingTransport([
      .init(
        data: Data(
          #"{"error":{"code":"provider_failed","message":"Failed","retryable":true}}"#.utf8),
        status: 503, headers: ["X-Request-ID": "request-1", "Retry-After": "5"])
    ])
    let config = try ServiceConfiguration(baseURL: URL(string: "https://example/ai")!, appID: "a")
    let client = HTTPClient(
      configuration: config, tokenProvider: { "test-token" }, transport: transport)
    do {
      let _: JSONValue = try await client.request(
        path: ["app", "a", "responses"], method: "POST", body: ["model": "test"])
      Issue.record("Expected API failure")
    } catch let error as APIError {
      #expect(error.status == 503)
      #expect(error.code == "provider_failed")
      #expect(error.requestID == "request-1")
      #expect(error.retryAfter == "5")
    }
    let requests = await transport.requests
    #expect(requests.count == 1)
    #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    #expect(requests.first?.value(forHTTPHeaderField: "X-App-ID") == "a")
  }
}
