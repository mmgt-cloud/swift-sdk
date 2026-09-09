import MMGTCore
import Observation

/// Connection state only. Domain events must be consumed and acknowledged by the application.
@MainActor @Observable public final class RealtimeState: ApplicationLifecycleParticipant {
  public let client: RealtimeClient
  public private(set) var connection: RealtimeConnectionState = .idle
  public private(set) var error: (any Error)?
  public init(client: RealtimeClient) { self.client = client }
  public func observe() async {
    for await state in await client.connectionStates() {
      if Task.isCancelled { return }
      connection = state
    }
  }
  public func connect() async throws {
    error = nil
    do {
      try await client.connect()
      connection = await client.state
    } catch {
      self.error = error
      connection = await client.state
      throw error
    }
  }
  public func disconnect() async {
    await client.disconnect()
    connection = await client.state
  }
  public func activityChanged(_ activity: ApplicationActivity) async {
    await client.activityChanged(activity)
    connection = await client.state
    if activity == .signedOut { error = nil }
  }
}
