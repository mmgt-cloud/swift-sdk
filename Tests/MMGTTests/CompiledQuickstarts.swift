import Foundation
import MMGTAI
import MMGTAuth
import MMGTBilling
import MMGTCore
import MMGTRealtime
import MMGTSwiftUI
import MMGTSync
import MMGTSyncSQLite
import SwiftUI

// These examples compile in the test target and the example app. DocC uses
// byte-checked excerpts; none of these functions run automatically in a test.

// snippet: MMGTCore
func configureService(baseURL: URL, appID: String) throws -> ServiceConfiguration {
  try ServiceConfiguration(baseURL: baseURL, appID: appID)
}
// end-snippet

// snippet: MMGTAuth
func signInWithPassword(session: AuthSession, email: String, password: String) async throws
  -> LoginResult
{
  try await session.authenticate { client in
    try await client.login(input: .init(email: email, password: password))
  }
}
// end-snippet

// snippet: MMGTBilling
func reloadAccessAfterCheckout(configuration: ServiceConfiguration, session: AuthSession)
  async throws -> BillingAccessResponse
{
  let client = BillingClient(
    configuration: configuration, tokenProvider: await session.tokenProvider)
  return try await client.getAccess()
}
// end-snippet

// snippet: MMGTRealtime
func consumeUserEvents(
  client: RealtimeClient,
  apply: @escaping @Sendable (RealtimeEvent) async throws -> Void,
  reconcile: @escaping @Sendable () async throws -> Void
) async throws {
  let messages = await client.messages()
  try await client.subscribe(.init(channel: RealtimeChannels.user(client.identity.userID)))
  do {
    try await client.connect()
    for try await message in messages {
      switch message {
      case .event(let event):
        try await apply(event)
        try await client.acknowledge(event)
      case .replayGap: try await reconcile()
      default: break
      }
    }
  } catch {
    await client.disconnect()
    throw error
  }
  await client.disconnect()
}
// end-snippet

// snippet: MMGTSync
func createOfflineNote(client: SyncClient, recordID: String, text: String) async throws
  -> SyncRunResult
{
  let mutationID = UUID().uuidString
  try await client.write(
    .init(
      collection: "notes", recordId: recordID, op: "upsert", data: ["text": .string(text)],
      mutationId: mutationID, baseVersion: "0"))
  return try await client.sync(scope: .init(collections: ["notes"]), maxPages: 100)
}
// end-snippet

// snippet: MMGTSyncSQLite
func configureOfflineSync(
  configuration: ServiceConfiguration, userID: String, session: AuthSession, databaseURL: URL
) async throws -> SyncClient {
  let store = try SQLiteSyncStore(fileURL: databaseURL)
  let client = try SyncClient(
    configuration: configuration, userID: userID, tokenProvider: await session.tokenProvider,
    store: store
  )
  await session.attach(client)
  return client
}
// end-snippet

// snippet: MMGTAI
func generateReply(client: AIClient, connectionID: String, model: String, prompt: String)
  async throws -> AIResponse
{
  let request = AIResponseRequest(
    connectionId: connectionID, model: model,
    input: [.init(role: "user", content: [.text(prompt)])])
  return try await client.generate(request)
}
// end-snippet

// snippet: MMGTSwiftUI
@MainActor struct SessionStatusView: View {
  @State var state: AuthState
  var body: some View {
    Text(state.snapshot?.identity == nil ? "Signed out" : "Signed in")
      .task { await state.observe() }
      .mmgtLifecycle(state)
  }
}
// end-snippet
