import Foundation
import MMGTCore

public struct AuthSessionSnapshot: Sendable, Equatable {
  public let identity: AccountIdentity?
  public let user: UserResponse?
  public let requiresTwoFactorSetup: Bool
}

/// One refresh owner per application session. Share its token provider with the service clients.
public actor AuthSession: ApplicationLifecycleParticipant {
  public nonisolated let configuration: ServiceConfiguration
  private let transport: any HTTPTransport
  private let store: any SessionStore
  private var current: PersistedSession?
  private var generation = UUID()
  private var refresh: (id: UUID, task: Task<AuthTokens, any Error>)?
  private var login: (id: UUID, task: Task<LoginOperation, any Error>)?
  private var restoration: (id: UUID, task: Task<RestoreOperation, any Error>)?
  private var participants: [any ApplicationLifecycleParticipant] = []
  private var observers: [UUID: AsyncStream<AuthSessionSnapshot>.Continuation] = [:]
  private var deletionFailed = false
  public private(set) var user: UserResponse?
  public private(set) var requiresTwoFactorSetup = false
  private struct LoginOperation: Sendable {
    let result: LoginResult
    let profile: UserResponse?
  }
  private struct RestoreOperation: Sendable {
    let tokens: AuthTokens
    let profile: Result<UserResponse, any Error>
  }

  public init(
    configuration: ServiceConfiguration, store: (any SessionStore)? = nil,
    transport: any HTTPTransport = URLSessionTransport()
  ) {
    self.configuration = configuration
    self.store = store ?? KeychainSessionStore(configuration: configuration)
    self.transport = transport
  }
  public nonisolated var tokenProvider: AccessTokenProvider { { try await self.accessToken() } }
  public var identity: AccountIdentity? { current?.identity }
  public var snapshot: AuthSessionSnapshot {
    .init(identity: current?.identity, user: user, requiresTwoFactorSetup: requiresTwoFactorSetup)
  }
  /// Full snapshots use a latest-value buffer; intermediate states do not need replay.
  public func snapshots() -> AsyncStream<AuthSessionSnapshot> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<AuthSessionSnapshot>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    observers[id] = continuation
    continuation.yield(snapshot)
    continuation.onTermination = { @Sendable _ in Task { await self.removeObserver(id) } }
    return stream
  }
  private func removeObserver(_ id: UUID) { observers[id] = nil }
  private func publish() { for observer in observers.values { observer.yield(snapshot) } }
  /// Attach only clients belonging to this account. Logout detaches and closes them.
  public func attach(_ participant: any ApplicationLifecycleParticipant) {
    participants.append(participant)
  }
  public func accessToken() async throws -> String {
    try Task.checkCancellation()
    guard let token = current?.tokens.accessToken else { throw MMGTError.unauthenticated }
    // JWT expiry is only a scheduling hint, never proof of identity or authorization.
    let value = Self.expiresSoon(token) ? try await refreshToken().accessToken : token
    try Task.checkCancellation()
    return value
  }
  private nonisolated static func expiresSoon(_ token: String) -> Bool {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return false }
    var part = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    part += String(repeating: "=", count: (4 - part.count % 4) % 4)
    guard let data = Data(base64Encoded: part),
      let payload = try? JSONDecoder().decode(JSONValue.self, from: data),
      let expiry = try? payload["exp"]?.decode(Double.self), expiry.isFinite
    else { return false }
    return expiry <= Date().timeIntervalSince1970 + 30
  }

  public func restore() async throws {
    if deletionFailed {
      try store.clear()
      deletionFailed = false
    }
    guard current == nil else { return }
    let expected = generation
    guard let saved = try store.load() else { return }
    guard
      saved.identity
        == (try? AccountIdentity(configuration: configuration, userID: saved.identity.userID))
    else {
      throw MMGTError.sessionChanged
    }
    let flight: (id: UUID, task: Task<RestoreOperation, any Error>)
    if let restoration {
      flight = restoration
    } else {
      let configuration = configuration
      let transport = transport
      flight = (
        UUID(),
        Task {
          var tokens = saved.tokens
          if Self.expiresSoon(tokens.accessToken) {
            tokens = try await AuthClient(configuration: configuration, transport: transport)
              .refreshToken(tokens.refreshToken)
          }
          let result: Result<UserResponse, any Error>
          do {
            let access = tokens.accessToken
            let profile = try await AuthClient(
              configuration: configuration, tokenProvider: { access }, transport: transport
            ).getProfile()
            result = .success(profile)
          } catch { result = .failure(error) }
          return RestoreOperation(tokens: tokens, profile: result)
        }
      )
      restoration = flight
    }
    defer { if restoration?.id == flight.id { restoration = nil } }
    let result = try await flight.task.value
    guard generation == expected else { throw MMGTError.sessionChanged }
    try Task.checkCancellation()
    guard restoration?.id == flight.id else { return }
    // Preserve a rotated refresh token even if the subsequent profile request loses connectivity.
    let updated = PersistedSession(identity: saved.identity, tokens: result.tokens)
    if result.tokens != saved.tokens { try store.save(updated) }
    let profile = try result.profile.get()
    guard profile.id == saved.identity.userID else { throw MMGTError.sessionChanged }
    current = updated
    user = profile
    publish()
  }

  /// Supply a native, password or MFA operation. The profile request is part of the cancellable login task.
  public func authenticate(
    _ operation: @escaping @Sendable (AuthClient) async throws -> LoginResult
  ) async throws -> LoginResult {
    let (expected, deletion, previous) = resetState()
    for participant in previous { await participant.activityChanged(.signedOut) }
    try deletion.get()
    guard generation == expected else { throw MMGTError.sessionChanged }
    let configuration = configuration
    let transport = transport
    let task = Task {
      let result = try await operation(
        AuthClient(configuration: configuration, transport: transport))
      let tokens: AuthTokens
      switch result {
      case .authenticated(let value), .requiresTwoFactorSetup(let value, _): tokens = value
      default: return LoginOperation(result: result, profile: nil)
      }
      let profile = try await AuthClient(
        configuration: configuration, tokenProvider: { tokens.accessToken }, transport: transport
      ).getProfile()
      return LoginOperation(result: result, profile: profile)
    }
    login = (expected, task)
    defer { if login?.id == expected { login = nil } }
    let output: LoginOperation
    do {
      output = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
    } catch {
      guard generation == expected else { throw MMGTError.sessionChanged }
      throw error
    }
    guard generation == expected else { throw MMGTError.sessionChanged }
    try Task.checkCancellation()
    let tokens: AuthTokens
    switch output.result {
    case .authenticated(let value): tokens = value
    case .requiresTwoFactorSetup(let value, _):
      tokens = value
      requiresTwoFactorSetup = true
    default: return output.result
    }
    guard let profile = output.profile else {
      throw MMGTError.invalidResponse("Login profile missing")
    }
    let session = PersistedSession(
      identity: try AccountIdentity(configuration: configuration, userID: profile.id),
      tokens: tokens)
    try store.save(session)
    current = session
    user = profile
    publish()
    return output.result
  }

  /// A shared refresh is canceled by logout, not by cancellation of one waiting request.
  public func refreshToken() async throws -> AuthTokens {
    guard let old = current else { throw MMGTError.unauthenticated }
    let expected = generation
    let flight: (id: UUID, task: Task<AuthTokens, any Error>)
    if let refresh {
      flight = refresh
    } else {
      let client = client()
      flight = (UUID(), Task { try await client.refreshToken(old.tokens.refreshToken) })
      refresh = flight
    }
    do {
      let tokens = try await flight.task.value
      guard expected == generation else { throw MMGTError.sessionChanged }
      if refresh?.id == flight.id {
        let value = PersistedSession(identity: old.identity, tokens: tokens)
        // Keep rotated tokens in memory if persistence fails; the error remains visible to the caller.
        current = value
        refresh = nil
        try store.save(value)
      }
      try Task.checkCancellation()
      return tokens
    } catch {
      if refresh?.id == flight.id { refresh = nil }
      throw error
    }
  }
  public func logout() async throws {
    let old = current
    try await signOutLocally()
    if let old { _ = try await client(token: old.tokens.accessToken).logout(tokens: old.tokens) }
  }
  public func deleteAccount(input: DeleteAccountRequest) async throws {
    guard let current else { throw MMGTError.unauthenticated }
    let expected = generation
    _ = try await client(token: current.tokens.accessToken).deleteAccount(input: input)
    if generation == expected { try await signOutLocally() }
  }
  public func signOutLocally() async throws {
    let (_, deletion, previous) = resetState()
    for participant in previous { await participant.activityChanged(.signedOut) }
    try deletion.get()
  }
  private func resetState() -> (
    UUID, Result<Void, any Error>, [any ApplicationLifecycleParticipant]
  ) {
    generation = UUID()
    refresh?.task.cancel()
    refresh = nil
    login?.task.cancel()
    login = nil
    restoration?.task.cancel()
    restoration = nil
    current = nil
    user = nil
    requiresTwoFactorSetup = false
    let previous = participants
    participants.removeAll()
    let result = Result { try store.clear() }
    if case .failure = result { deletionFailed = true } else { deletionFailed = false }
    publish()
    return (generation, result, previous)
  }
  public func activityChanged(_ activity: ApplicationActivity) async {
    if activity == .signedOut {
      try? await signOutLocally()
      return
    }
    let expected = generation
    for participant in participants {
      guard generation == expected else { return }
      await participant.activityChanged(activity)
    }
  }
  private func client(token: String? = nil) -> AuthClient {
    AuthClient(
      configuration: configuration, tokenProvider: token.map { value in { @Sendable in value } },
      transport: transport)
  }
}
