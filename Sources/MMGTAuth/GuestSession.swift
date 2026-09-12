import Foundation
import MMGTCore
import Security

public struct GuestSessionError: Error, Sendable, Equatable {
  public let code: String
  public init(_ code: String) { self.code = code }
}
public struct GuestSessionSummary: Sendable, Equatable {
  public enum Status: String, Sendable { case local, active, revoking, revoked, expired }
  public let status: Status
  public let guestID: String?
  public let expiresAt: String?
}

/// A technical AI session, independent of AuthSession and a local guest's domain data.
/// Construction and summary are offline; an explicit accessToken() starts online access.
public actor GuestSession: ApplicationLifecycleParticipant {
  public nonisolated let configuration: ServiceConfiguration
  public nonisolated let profileID: String
  public nonisolated let partition: String
  private let store: any GuestSessionStore
  private let client: HTTPClient
  private let now: @Sendable () -> Date
  private var generation = UUID()
  private var closed = false
  private var revoking = false
  private var flight: (id: UUID, secret: String, task: Task<GuestCredentials, any Error>)?
  private var observers: [UUID: AsyncStream<GuestSessionSummary>.Continuation] = [:]

  public init(
    configuration: ServiceConfiguration, profileID: String,
    store: any GuestSessionStore = KeychainGuestSessionStore(),
    transport: any HTTPTransport = URLSessionTransport()
  ) throws {
    try self.init(
      configuration: configuration, profileID: profileID, store: store, transport: transport,
      now: { Date() })
  }
  init(
    configuration: ServiceConfiguration, profileID: String, store: any GuestSessionStore,
    transport: any HTTPTransport, now: @escaping @Sendable () -> Date
  ) throws {
    guard !profileID.isEmpty, profileID.count <= 200,
      profileID.trimmingCharacters(in: .whitespacesAndNewlines) == profileID,
      !profileID.contains("\0")
    else {
      throw MMGTError.invalidConfiguration("An explicit saved local guest profile ID is required")
    }
    self.configuration = configuration
    self.profileID = profileID
    self.store = store
    self.now = now
    self.client = HTTPClient(configuration: configuration, transport: transport)
    partition = String(
      decoding: try JSONEncoder().encode(["guest-ai-v1", configuration.storagePartition, profileID]
      ), as: UTF8.self)
  }
  public var tokenProvider: AccessTokenProvider {
    let expected = generation
    return {
      try await self.accessToken(expected: expected)
    }
  }
  public func summary() throws -> GuestSessionSummary {
    let row = try store.load(partition: partition)
    return .init(
      status: row.map { .init(rawValue: $0.phase.rawValue)! } ?? .local,
      guestID: row?.credentials?.guestID, expiresAt: row?.credentials?.expiresAt)
  }
  /// Latest state for this owner. Another store instance is checked before every token request.
  public func snapshots() throws -> AsyncStream<GuestSessionSummary> {
    let snapshot = try summary()
    let id = UUID()
    let (stream, continuation) = AsyncStream<GuestSessionSummary>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    observers[id] = continuation
    continuation.yield(snapshot)
    continuation.onTermination = { @Sendable _ in Task { await self.removeObserver(id) } }
    return stream
  }
  private func removeObserver(_ id: UUID) { observers[id] = nil }
  private func publish() throws {
    let value = try summary()
    for observer in observers.values { observer.yield(value) }
  }
  private func check(_ expected: UUID) throws {
    try Task.checkCancellation()
    guard !closed, generation == expected else { throw MMGTError.sessionChanged }
    guard !revoking else { throw GuestSessionError("guest_session_revoked") }
  }
  private func terminal(_ phase: GuestSessionPhase) throws {
    guard phase == .active else {
      throw GuestSessionError(phase == .expired ? "guest_session_expired" : "guest_session_revoked")
    }
  }
  public func accessToken() async throws -> String { try await accessToken(expected: generation) }
  private func accessToken(expected: UUID) async throws -> String {
    try check(expected)
    var row = try store.load(partition: partition)
    if row == nil {
      let initial = GuestStoredSession(phase: .active, renewalSecret: try Self.renewalSecret())
      _ = try store.compareAndSwap(partition: partition, expectedRevision: nil, next: initial)
      row = try store.load(partition: partition)
    }
    guard let saved = row, let secret = saved.renewalSecret else {
      if let row { try terminal(row.phase) }
      throw MMGTError.invalidResponse("Guest store did not retain its committed credential")
    }
    try terminal(saved.phase)
    if let credentials = saved.credentials,
      try WireDate.parse(credentials.expiresAt) > now().addingTimeInterval(30)
    {
      try validate(credentials)
      return credentials.accessToken
    }
    let pending: (id: UUID, secret: String, task: Task<GuestCredentials, any Error>)
    if let flight {
      guard flight.secret == secret else { throw MMGTError.sessionChanged }
      pending = flight
    } else {
      let client = self.client
      let path = saved.credentials == nil ? ["guest", "sessions"] : ["guest", "sessions", "renew"]
      pending = (
        UUID(), secret,
        Task {
          try await client.request(
            GuestCredentials.self, path: path, method: "POST",
            body: .object(["renewal_secret": .string(secret)]), authenticated: false,
            headers: ["Cache-Control": "no-store"])
        }
      )
      flight = pending
    }
    defer { if flight?.id == pending.id { flight = nil } }
    let credentials: GuestCredentials
    do { credentials = try await pending.task.value } catch {
      try check(expected)
      if let api = error as? APIError, api.code == "guest_session_expired" {
        var expired = saved
        expired.revision = UUID().uuidString
        expired.phase = .expired
        _ = try store.compareAndSwap(
          partition: partition, expectedRevision: saved.revision, next: expired)
        try publish()
      }
      throw error
    }
    try check(expected)
    try validate(credentials, previous: saved.credentials)
    var next = saved
    next.revision = UUID().uuidString
    next.credentials = credentials
    if !(try store.compareAndSwap(
      partition: partition, expectedRevision: saved.revision, next: next))
    {
      guard let current = try store.load(partition: partition) else {
        throw MMGTError.sessionChanged
      }
      try terminal(current.phase)
      guard current.renewalSecret == secret, let value = current.credentials,
        value.guestID == credentials.guestID
      else { throw MMGTError.sessionChanged }
      try validate(value)
      return value.accessToken
    }
    try publish()
    return credentials.accessToken
  }
  private func validate(_ value: GuestCredentials, previous: GuestCredentials? = nil) throws {
    guard let issuerURL = URL(string: value.issuer),
      let issuer = try? ServiceConfiguration(baseURL: issuerURL, appID: value.appID),
      issuer.storagePartition == configuration.storagePartition,
      value.appID == configuration.appID, value.purpose == "ai",
      UUID(uuidString: value.guestID) != nil,
      previous == nil || previous?.guestID == value.guestID,
      value.accessToken.hasPrefix("mmgt_ga_"), value.accessToken.utf8.count == 51,
      value.accessToken.dropFirst(8).utf8.allSatisfy({
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
          || $0 == 95
      }),
      let expiry = try? WireDate.parse(value.expiresAt),
      let idle = try? WireDate.parse(value.idleExpiresAt),
      expiry > now(), expiry <= now().addingTimeInterval(330), idle >= expiry
    else { throw GuestSessionError("guest_invalid_response") }
  }
  /// A lost response leaves the durable revoking marker; calling revoke() again resumes it.
  public func revoke() async throws {
    revoking = true
    generation = UUID()
    flight?.task.cancel()
    flight = nil
    var saved: GuestStoredSession?
    for _ in 0..<64 {
      let current = try store.load(partition: partition)
      if current?.phase == .revoked || current?.phase == .expired {
        try publish()
        return
      }
      if current?.phase == .revoking {
        saved = current
        break
      }
      var next = current ?? GuestStoredSession(phase: .revoked)
      next.revision = UUID().uuidString
      next.phase = current == nil ? .revoked : .revoking
      if try store.compareAndSwap(
        partition: partition, expectedRevision: current?.revision, next: next)
      {
        saved = next
        break
      }
    }
    guard let saved else { throw GuestSessionError("guest_storage_contention") }
    try publish()
    if saved.phase == .revoked { return }
    guard let secret = saved.renewalSecret else {
      throw MMGTError.invalidResponse("Guest revocation credential missing")
    }
    _ = try await client.send(
      path: ["guest", "sessions", "revoke"], method: "POST",
      data: JSONEncoder().encode(["renewal_secret": secret]), authenticated: false,
      headers: ["Cache-Control": "no-store"])
    if let current = try store.load(partition: partition), current.phase == .revoking,
      current.renewalSecret == secret
    {
      _ = try store.compareAndSwap(
        partition: partition, expectedRevision: current.revision, next: .init(phase: .revoked))
    }
    try publish()
  }
  /// Explicit new technical identity after expiry or completed revocation. Never quota recovery.
  public func startNewSession() throws {
    guard !closed else { throw MMGTError.sessionChanged }
    guard let current = try store.load(partition: partition),
      current.phase == .revoked || current.phase == .expired
    else {
      throw GuestSessionError("guest_previous_session_active")
    }
    let next = GuestStoredSession(phase: .active, renewalSecret: try Self.renewalSecret())
    guard
      try store.compareAndSwap(partition: partition, expectedRevision: current.revision, next: next)
    else { throw GuestSessionError("guest_storage_contention") }
    generation = UUID()
    revoking = false
    try publish()
  }
  public func close() {
    closed = true
    generation = UUID()
    flight?.task.cancel()
    flight = nil
    for continuation in observers.values { continuation.finish() }
    observers.removeAll()
  }
  public func activityChanged(_ activity: ApplicationActivity) async {
    if activity == .signedOut { close() }
  }
  private static func renewalSecret() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = bytes.withUnsafeMutableBytes {
      SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
    }
    guard status == errSecSuccess else { throw KeychainError(status: status) }
    return "mmgt_gr_"
      + Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}
