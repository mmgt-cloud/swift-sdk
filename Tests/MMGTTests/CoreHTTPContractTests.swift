import Foundation
import MMGTCore
import Testing

@Suite(.timeLimit(.minutes(1))) struct CoreHTTPContractTests {
  func configuration() throws -> ServiceConfiguration {
    try .init(baseURL: URL(string: "https://api.example.invalid/auth")!, appID: "synthetic-app")
  }

  @Test(arguments: [
    "Authorization", "authorization", "X-App-ID", "Host", "Cookie", "x-test\r\nInjected", "",
    "X:Invalid", "X Invalid", "X-ą",
  ])
  func reservedHeadersCannotOverrideIdentity(_ name: String) async throws {
    let transport = RecordingTransport([.init(data: Data("{}".utf8), status: 200)])
    let client = HTTPClient(
      configuration: try configuration(), tokenProvider: { "synthetic-access" },
      transport: transport)
    await #expect(
      throws: MMGTError.invalidConfiguration("A reserved or invalid HTTP header was supplied")
    ) {
      _ = try await client.send(path: ["profile"], headers: [name: "synthetic-value"])
    }
    #expect(await transport.requests.isEmpty)
  }

  @Test(arguments: [
    "valid\r\nInjected: true", "valid\rInjected", "valid\nInjected", "bad\0value", "bad\u{7f}value",
  ])
  func malformedHeaderValuesAreRejectedBeforeTransport(_ value: String) async throws {
    let transport = RecordingTransport([.init(data: Data("{}".utf8), status: 200)])
    let client = HTTPClient(
      configuration: try configuration(), tokenProvider: { "synthetic-access" },
      transport: transport)
    await #expect(
      throws: MMGTError.invalidConfiguration("A reserved or invalid HTTP header was supplied")
    ) {
      _ = try await client.send(path: ["profile"], headers: ["X-Synthetic": value])
    }
    #expect(await transport.requests.isEmpty)
  }

  @Test func cancellationWhileAcquiringTokenCannotReachTransport() async throws {
    let tokenGate = ControlledTransport()
    let transport = RecordingTransport([])
    let client = HTTPClient(
      configuration: try configuration(),
      tokenProvider: {
        _ = try await tokenGate.send(URLRequest(url: URL(string: "https://token.example.invalid")!))
        return "synthetic-access"
      }, transport: transport)
    let operation = Task { try await client.send(path: ["profile"]) }
    await tokenGate.waitForRequest(0)
    operation.cancel()
    await tokenGate.reply(0, "{}")
    await #expect(throws: CancellationError.self) { _ = try await operation.value }
    #expect(await transport.requests.isEmpty)
  }

  @Test func cancelledLateHTTPResultCannotSucceedOrRetry() async throws {
    let transport = ControlledTransport()
    let client = HTTPClient(
      configuration: try configuration(), tokenProvider: { "synthetic-access" },
      transport: transport)
    let operation = Task {
      try await client.request(
        JSONValue.self, path: ["profile"], method: "PUT", body: ["name": "Synthetic"])
    }
    await transport.waitForRequest(0)
    operation.cancel()
    await transport.reply(0, #"{"message":"Completed on server"}"#)
    await #expect(throws: CancellationError.self) { _ = try await operation.value }
    #expect(await transport.requests.count == 1)
  }

  @Test func publicRequestsNeverAskForTokenAndMalformedSuccessIsExplicit() async throws {
    struct Required: Decodable, Sendable { let required: String }
    let transport = RecordingTransport([.init(data: Data(#"{"different":true}"#.utf8), status: 200)]
    )
    let client = HTTPClient(
      configuration: try configuration(), tokenProvider: { throw MMGTError.sessionChanged },
      transport: transport)
    await #expect(throws: MMGTError.invalidResponse("Response did not match Required")) {
      _ = try await client.request(
        Required.self, path: ["app-config", "synthetic-app"], authenticated: false)
    }
    let request = try #require(await transport.requests.first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(await transport.requests.count == 1)
  }
}
