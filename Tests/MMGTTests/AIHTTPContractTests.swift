import Foundation
import MMGTAI
import MMGTCore
import Testing

@Suite struct AIHTTPContractTests {
  private func client(_ transport: RecordingTransport) throws -> AIClient {
    AIClient(
      configuration: try .init(
        baseURL: URL(string: "https://api.example.invalid/ai")!,
        appID: "11111111-1111-4111-8111-111111111111"), tokenProvider: { "synthetic-token" },
      transport: transport)
  }
  @Test func catalogGenerationAndFilesUseAuthenticatedAppRoutesOnce() async throws {
    let fixtures = SharedWireContractTests()
    let transport = RecordingTransport(
      try ["ai-catalog", "ai-response", "ai-file"].map {
        .init(data: try fixtures.data($0), status: $0 == "ai-file" ? 201 : 200)
      } + [.init(data: Data(), status: 204)])
    let sdk = try client(transport)
    let catalog = try await sdk.catalog()
    let model = try #require(catalog.models.first)
    #expect(catalog.status == "available" && model.enabled && model.id == "synthetic-model")
    // Runtime catalog deliberately exposes models, not administrator connection metadata.
    let input = AIResponseRequest(
      connectionId: model.connectionId, model: model.id,
      input: [.init(role: "user", content: [.text("hello")])], maxOutputTokens: 4)
    let generated = try await sdk.generate(input)
    #expect(try JSONValue.encoding(generated) == fixtures.decode("ai-response", as: JSONValue.self))
    let bytes = Data([97, 10, 195, 169])
    let file = try await sdk.upload(
      data: bytes, filename: "synthetic.txt", contentType: "text/plain")
    #expect(try JSONValue.encoding(file) == fixtures.decode("ai-file", as: JSONValue.self))
    try await sdk.deleteFile(file.id)
    let requests = await transport.requests
    #expect(requests.count == 4)
    #expect(requests.map(\.httpMethod) == ["GET", "POST", "POST", "DELETE"])
    #expect(
      requests.map { $0.url!.path }
        == ["catalog", "responses", "files", "files/" + file.id].map {
          "/ai/app/" + sdk.configuration.appID + "/" + $0
        })
    #expect(
      requests.allSatisfy {
        $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token"
          && $0.value(forHTTPHeaderField: "X-App-ID") == sdk.configuration.appID
      })
    #expect(try JSONDecoder().decode(AIResponseRequest.self, from: requests[1].httpBody!) == input)
    let type = try #require(requests[2].value(forHTTPHeaderField: "Content-Type"))
    let boundary = try #require(type.components(separatedBy: "boundary=").last)
    var expected = Data(
      "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"synthetic.txt\"\r\nContent-Type: text/plain\r\n\r\n"
        .utf8)
    expected.append(bytes)
    expected.append(Data("\r\n--\(boundary)--\r\n".utf8))
    #expect(requests[2].httpBody == expected)
    #expect(requests[3].httpBody == nil)
  }

  @Test func invalidUploadMetadataAndImplicitModelNeverReachTransport() async throws {
    let transport = RecordingTransport([])
    let sdk = try client(transport)
    for name in ["", "bad\r\nX-Injected: true", "bad\"name", "bad\\name"] {
      await #expect(throws: MMGTError.self) {
        _ = try await sdk.upload(data: Data(), filename: name, contentType: "text/plain")
      }
    }
    await #expect(throws: MMGTError.self) {
      _ = try await sdk.upload(
        data: Data(), filename: "safe.txt", contentType: "text/plain\r\nX-Injected: true")
    }
    for (connection, model) in [("", "explicit-model"), ("explicit-connection", "")] {
      await #expect(throws: MMGTError.self) {
        _ = try await sdk.generate(.init(connectionId: connection, model: model, input: []))
      }
    }
    #expect(await transport.requests.isEmpty)
  }

  @Test(arguments: [429, 500, 503])
  func providerFailureNeverRetriesGenerationOrChangesModel(_ status: Int) async throws {
    let transport = RecordingTransport([
      .init(
        data: Data(
          #"{"error":{"code":"provider_unavailable","message":"Synthetic failure","retryable":true}}"#
            .utf8), status: status,
        headers: ["X-Request-ID": "synthetic-request", "Retry-After": "30"])
    ])
    let sdk = try client(transport)
    do {
      _ = try await sdk.generate(WebSocketTests().input())
      Issue.record("Expected provider failure")
    } catch let error as APIError {
      #expect(
        error.code == "provider_unavailable" && error.status == status
          && error.requestID == "synthetic-request" && error.retryAfter == "30")
    }
    #expect(await transport.requests.count == 1)
  }
}
