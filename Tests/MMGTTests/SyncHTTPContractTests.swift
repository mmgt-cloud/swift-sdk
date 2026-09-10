import Foundation
import MMGTCore
import MMGTSync
import Testing

private actor SyncGrantRecorder {
  var scopes: [SyncScope] = []
  func grant(_ scope: SyncScope) -> String {
    scopes.append(scope)
    return "synthetic-grant-\(scopes.count)"
  }
}
private actor SyncTokenSource {
  private var count = 0
  func token() -> String {
    count += 1
    return "synthetic-token-\(count)"
  }
}

@Suite(.timeLimit(.minutes(1))) struct SyncHTTPContractTests {
  @Test func tokenProviderIsReadForEveryRequestWithoutReplacingIdentity() async throws {
    let tokens = SyncTokenSource()
    let transport = RecordingTransport(
      Array(
        repeating: .init(
          data: Data(#"{"changes":[],"next_cursor":"same-feed","has_more":false}"#.utf8),
          status: 200), count: 2))
    let config = try ServiceConfiguration(
      baseURL: URL(string: "https://api.example.invalid/sync")!, appID: "app-a")
    let sdk = try SyncClient(
      configuration: config, userID: "user-a", tokenProvider: { await tokens.token() },
      transport: transport)
    _ = try await sdk.pull()
    _ = try await sdk.pull(.init(cursor: "same-feed"))
    #expect(
      await transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == [
        "Bearer synthetic-token-1", "Bearer synthetic-token-2",
      ])
    #expect(sdk.identity == (try AccountIdentity(configuration: config, userID: "user-a")))
  }

  @Test(arguments: [
    "unknown", "duplicate", "collection", "record", "status", "version", "missingVersion",
    "missingConflictID",
  ])
  func invalidPushSettlementFailsAsAWhole(_ invalid: String) async throws {
    var result = SyncPushResult(
      mutationId: "a", collection: "notes", recordId: "note-a", status: "applied", version: "1")
    switch invalid {
    case "unknown": result.mutationId = "other"
    case "collection": result.collection = "other"
    case "record": result.recordId = "other"
    case "status": result.status = "unexpected"
    case "version": result.version = "01"
    case "missingVersion": result.version = nil
    case "missingConflictID": result.status = "conflict"
    default: break
    }
    let transport = RecordingTransport([
      .init(
        data: try JSONEncoder().encode(
          SyncPushResponse(results: invalid == "duplicate" ? [result, result] : [result])),
        status: 200)
    ])
    await #expect(throws: SyncStoreError.self) {
      _ = try await client(transport).push(
        .init(
          clientId: "original-device",
          mutations: [
            .init(
              collection: "notes", recordId: "note-a", op: "upsert", mutationId: "a",
              baseVersion: "0")
          ]))
    }
    #expect(await transport.requests.count == 1)
  }
  func client(_ transport: any HTTPTransport, grantProvider: SyncGrantProvider? = nil) throws
    -> SyncClient
  {
    try .init(
      configuration: .init(
        baseURL: URL(string: "https://api.example.invalid/sync")!,
        appID: "11111111-1111-4111-8111-111111111111"),
      userID: "22222222-2222-4222-8222-222222222222", tokenProvider: { "synthetic-token" },
      grantProvider: grantProvider, clientID: "synthetic-client", transport: transport)
  }
  @Test func allPublicHTTPRoutesUseActualDTOsAndNeverAdvancePullThroughPush() async throws {
    let fixture = SharedWireContractTests()
    let transport = RecordingTransport(
      try ["bootstrap", "pull", "push", "snapshot"].map {
        .init(data: try fixture.data("sync-" + $0), status: 200)
      })
    let sdk = try client(transport)
    #expect(
      try await sdk.bootstrap()
        == fixture.roundTrip("sync-bootstrap", as: SyncBootstrapResponse.self))
    #expect(
      try await sdk.pull(.init(cursor: "opaque+/=?", limit: 16, collections: ["synthetic_notes"]))
        == fixture.decode("sync-pull", as: SyncPullResponse.self))
    let results = try fixture.decode("sync-push", as: SyncPushResponse.self)
    let push = SyncPushRequest(
      clientId: "original-device",
      mutations: results.results.map {
        .init(
          collection: $0.collection, recordId: $0.recordId, op: "upsert",
          data: ["enabled": false, "cleared": nil], mutationId: $0.mutationId,
          baseVersion: "9007199254740993")
      })
    #expect(try await sdk.push(push) == results)
    #expect(
      try await sdk.snapshot(
        .init(collections: ["synthetic_notes"], pageToken: "opaque-page", limit: 16))
        == fixture.decode("sync-snapshot", as: SyncSnapshotResponse.self))
    let requests = await transport.requests
    #expect(requests.map(\.httpMethod) == ["GET", "POST", "POST", "POST"])
    #expect(
      requests.map { $0.url!.path }
        == ["bootstrap", "pull", "push", "snapshot"].map {
          "/sync/app/11111111-1111-4111-8111-111111111111/" + $0
        })
    #expect(
      requests.allSatisfy {
        $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token"
          && $0.value(forHTTPHeaderField: "X-App-ID") == "11111111-1111-4111-8111-111111111111"
          && $0.value(forHTTPHeaderField: "X-Sync-Grant") == nil
      })
    #expect(requests[0].httpBody == nil && requests[0].url?.query == nil)
    let pull = try JSONDecoder().decode(SyncPullRequest.self, from: requests[1].httpBody!)
    #expect(pull.clientId == "synthetic-client" && pull.cursor == "opaque+/=?" && pull.limit == 16)
    #expect(try JSONDecoder().decode(SyncPushRequest.self, from: requests[2].httpBody!) == push)
    #expect(
      try JSONDecoder().decode(SyncSnapshotRequest.self, from: requests[3].httpBody!)
        == .init(collections: ["synthetic_notes"], pageToken: "opaque-page", limit: 16))
  }

  @Test func everyWorkspaceOperationRenewsItsGrantForCanonicalScope() async throws {
    let fixture = SharedWireContractTests()
    let transport = RecordingTransport([
      .init(data: try fixture.data("sync-bootstrap"), status: 200),
      .init(
        data: Data(#"{"changes":[],"next_cursor":"same-scope","has_more":false}"#.utf8), status: 200
      ),
      .init(data: Data(#"{"results":[]}"#.utf8), status: 200),
      .init(
        data: Data(
          #"{"records":[],"watermark":"5","cursor":"same-scope","has_more":false,"expires_at":"2030-01-01T00:00:00Z"}"#
            .utf8), status: 200),
    ])
    let grants = SyncGrantRecorder()
    let sdk = try client(transport, grantProvider: { await grants.grant($0) })
    let scope = try SyncScope(collections: ["team", "team"], workspaceIDs: ["b", "a", "b"])
    _ = try await sdk.bootstrap(scope: scope)
    _ = try await sdk.pull(.init(collections: ["team", "team"], workspaceIds: ["b", "a", "b"]))
    _ = try await sdk.push(
      .init(
        clientId: "device",
        mutations: ["b", "a"].map {
          .init(
            collection: "team", recordId: $0, op: "delete", mutationId: $0, baseVersion: "5",
            workspaceId: $0)
        }))
    _ = try await sdk.snapshot(
      .init(collections: scope.collections, workspaceIds: scope.workspaceIDs))
    #expect(await grants.scopes == Array(repeating: scope, count: 4))
    #expect(
      await transport.requests.map { $0.value(forHTTPHeaderField: "X-Sync-Grant") }
        == (1...4).map { "synthetic-grant-\($0)" })
  }

  @Test(arguments: ["bootstrap", "pull", "push", "snapshot"])
  func missingWorkspaceGrantFailsBeforeNetwork(_ operation: String) async throws {
    let transport = RecordingTransport([])
    let sdk = try client(transport)
    await #expect(throws: MMGTError.unauthenticated) {
      switch operation {
      case "bootstrap":
        _ = try await sdk.bootstrap(scope: .init(collections: ["team"], workspaceIDs: ["a"]))
      case "pull": _ = try await sdk.pull(.init(collections: ["team"], workspaceIds: ["a"]))
      case "push":
        _ = try await sdk.push(
          .init(
            clientId: "device",
            mutations: [
              .init(
                collection: "team", recordId: "a", op: "delete", mutationId: "a", baseVersion: "5",
                workspaceId: "a")
            ]))
      default: _ = try await sdk.snapshot(.init(collections: ["team"], workspaceIds: ["a"]))
      }
    }
    #expect(await transport.requests.isEmpty)
  }

  @Test(arguments: ["owner", "workspace", "collection", "tombstone", "version", "date", "cursor"])
  func rejectsChangesOutsideIdentityAndWireContract(_ invalid: String) async throws {
    var response = try SharedWireContractTests().decode("sync-pull", as: SyncPullResponse.self)
    switch invalid {
    case "owner": response.changes[0].userId = "another-user"
    case "workspace": response.changes[0].workspaceId = "another-workspace"
    case "collection": response.changes[0].collection = "another-collection"
    case "tombstone":
      response.changes[0].op = "delete"
      response.changes[0].userId = "another-user"
    case "version": response.changes[0].version = "9223372036854775808"
    case "date": response.changes[0].createdAt = "not-a-date"
    default: response.nextCursor = ""
    }
    let transport = RecordingTransport([
      .init(data: try JSONEncoder().encode(response), status: 200)
    ])
    await #expect(throws: SyncStoreError.self) {
      _ = try await client(transport).pull(.init(collections: ["synthetic_notes"]))
    }
    #expect(await transport.requests.count == 1)
  }

  @Test(arguments: [400, 403, 410, 429, 503])
  func errorsKeepContractCodesAndNeverRetry(_ status: Int) async throws {
    let transport = RecordingTransport([
      .init(
        data: Data(#"{"error":"scope_mismatch"}"#.utf8), status: status,
        headers: ["X-Request-ID": "synthetic-request", "Retry-After": "30"])
    ])
    do {
      _ = try await client(transport).pull()
      Issue.record("Expected error")
    } catch let error as APIError {
      #expect(
        error.status == status && error.code == "scope_mismatch"
          && error.requestID == "synthetic-request" && error.retryAfter == "30")
    }
    #expect(await transport.requests.count == 1)
  }
}
