import Foundation
import MMGTAuth
import MMGTCore
import Testing

private enum AuthReadOperation: String, CaseIterable, Sendable {
  case profile, updateProfile, socialAccounts, sessions, activity, activityEntry, eventTypes,
    exportJSON
}

@Suite struct AuthProfileContractTests {
  @Test(arguments: AuthReadOperation.allCases)
  private func profileSessionAndActivityWireContract(_ operation: AuthReadOperation) async throws {
    let fixtures = SharedWireContractTests()
    let profile: JSONValue = try fixtures.decode("auth-profile")
    let activity: JSONValue = try fixtures.decode("auth-activity")
    guard case .array(let events) = activity["data"] else {
      throw MMGTError.invalidResponse("Invalid synthetic activity fixture")
    }
    let event = try #require(events.first)
    var path: String
    var query: [String: String] = [:]
    var method = "GET"
    var body: JSONValue?
    let wire: JSONValue
    switch operation {
    case .profile, .updateProfile:
      path = "/auth/profile"
      wire = profile
      if operation == .updateProfile {
        method = "PUT"
        body = ["first_name": "Synthetic", "locale": "en"]
      }
    case .socialAccounts:
      path = "/auth/profile/social-accounts"
      wire = try fixtures.decode("auth-social")
    case .sessions:
      path = "/auth/sessions"
      wire = try fixtures.decode("auth-sessions")
    case .activity:
      path = "/auth/activity-logs"
      query = [
        "page": "1", "limit": "10", "event_type": "PROFILE_UPDATED", "start_date": "2026-09-01",
        "end_date": "2026-09-10",
      ]
      wire = activity
    case .activityEntry:
      path = "/auth/activity-logs/77777777-7777-4777-8777-777777777777"
      wire = event
    case .eventTypes:
      path = "/auth/activity-logs/event-types"
      wire = ["event_types": ["PROFILE_UPDATED", "USER_LOGIN"]]
    case .exportJSON:
      path = "/auth/activity-logs/export"
      query = [
        "format": "json", "event_type": "PROFILE_UPDATED", "start_date": "2026-09-01",
        "end_date": "2026-09-10",
      ]
      wire = try fixtures.decode("auth-export")
    }
    let transport = RecordingTransport([.init(data: try JSONEncoder().encode(wire), status: 200)])
    let client = AuthClient(
      configuration: try .init(
        baseURL: URL(string: "https://api.example.invalid/auth")!,
        appID: "11111111-1111-4111-8111-111111111111"), tokenProvider: { "synthetic-access" },
      transport: transport)
    let result: JSONValue
    switch operation {
    case .profile: result = try .encoding(await client.getProfile())
    case .updateProfile:
      result = try .encoding(
        await client.updateProfile(input: .init(firstName: "Synthetic", locale: "en")))
    case .socialAccounts: result = try .encoding(await client.listSocialAccounts())
    case .sessions: result = try .encoding(await client.listSessions())
    case .activity:
      result = try .encoding(
        await client.listActivityLogs(
          page: 1, limit: 10, eventType: "PROFILE_UPDATED", startDate: "2026-09-01",
          endDate: "2026-09-10"))
    case .activityEntry:
      result = try .encoding(
        await client.getActivityLog(id: "77777777-7777-4777-8777-777777777777"))
    case .eventTypes: result = try .encoding(await client.getActivityEventTypes())
    case .exportJSON:
      result = try .encoding(
        await client.exportActivityLogs(
          eventType: "PROFILE_UPDATED", startDate: "2026-09-01", endDate: "2026-09-10"))
    }
    #expect(result == wire)
    let requests = await transport.requests
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(request.httpMethod == method && request.url?.path == path)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access")
    #expect(request.value(forHTTPHeaderField: "X-App-ID") == client.configuration.appID)
    let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
    #expect(
      Dictionary(
        uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        == query)
    #expect(try request.httpBody.map { try JSONDecoder().decode(JSONValue.self, from: $0) } == body)
  }

  @Test func activityCSVPreservesTextAndExplicitFormat() async throws {
    let csv = "\u{FEFF}id,event_type\r\nsynthetic,PROFILE_UPDATED\r\n"
    let transport = RecordingTransport([
      .init(data: Data(csv.utf8), status: 200, headers: ["Content-Type": "text/csv"])
    ])
    let client = AuthClient(
      configuration: try .init(
        baseURL: URL(string: "https://api.example.invalid/auth")!, appID: "synthetic-app"),
      tokenProvider: { "synthetic-access" }, transport: transport)
    #expect(try await client.exportActivityCSV() == csv)
    let requests = await transport.requests
    #expect(requests.count == 1 && requests[0].url?.query == "format=csv")
  }

  @Test(arguments: [401, 403, 429, 503])
  func profileWriteFailureDoesNotRefreshOrRepeat(_ status: Int) async throws {
    let transport = RecordingTransport([
      .init(
        data: Data(#"{"error":"synthetic_denial"}"#.utf8), status: status,
        headers: ["X-Request-ID": "synthetic-request"])
    ])
    let client = AuthClient(
      configuration: try .init(
        baseURL: URL(string: "https://api.example.invalid/auth")!, appID: "synthetic-app"),
      tokenProvider: { "synthetic-access" }, transport: transport)
    do {
      _ = try await client.updateProfile(input: .init(firstName: "Synthetic"))
      Issue.record("Expected explicit failure")
    } catch let error as APIError {
      #expect(
        error.status == status && error.code == "synthetic_denial"
          && error.requestID == "synthetic-request")
    }
    #expect(await transport.requests.count == 1)
  }
}
