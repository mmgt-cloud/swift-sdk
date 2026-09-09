import Foundation
import MMGTAI
import MMGTAuth
import MMGTCore
import Testing

@Suite(.timeLimit(.minutes(1))) struct StateTests {
  @MainActor @Test func resourceCannotRegressAfterOverlappingLoadsOrLogout() async throws {
    let transport = ControlledTransport()
    let configuration = try ServiceConfiguration(
      baseURL: URL(string: "https://example.invalid")!, appID: "synthetic-app")
    let client = HTTPClient(configuration: configuration, transport: transport)
    let state = ResourceState<JSONValue> {
      try await client.request(path: ["state"], authenticated: false)
    }
    let old = Task { try await state.reload() }
    await transport.waitForRequest(0)
    let fresh = Task { try await state.reload() }
    await transport.waitForRequest(1)
    await transport.reply(1, #"{"version":"2"}"#)
    _ = try await fresh.value
    await transport.reply(0, #"{"version":"1"}"#)
    await #expect(throws: (any Error).self) { try await old.value }
    #expect(state.value?["version"]?.string == "2")
    let pending = Task { try await state.reload() }
    await transport.waitForRequest(2)
    await state.activityChanged(.signedOut)
    await transport.reply(2, #"{"version":"3"}"#)
    await #expect(throws: (any Error).self) { try await pending.value }
    #expect(state.value == nil)
    #expect(!state.isLoading)
    await #expect(throws: MMGTError.sessionChanged) { try await state.reload() }
  }
}
