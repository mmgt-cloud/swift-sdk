import Foundation
import MMGTAI
import MMGTAuth
import MMGTCore
import MMGTSync
import MMGTSyncSQLite
import Observation
import UniformTypeIdentifiers

@MainActor @Observable final class PersonalSpaceModel: ApplicationLifecycleParticipant {
  struct Confirmation: Identifiable {
    let id: UUID
    let message: String
  }
  private struct Runtime {
    let guest: LocalReplica
    let replica: LocalReplica
    let guestSession: GuestSession
    let ai: AIClient
    let userID: String?
    let authenticated: Bool
    var domain: PersonalDomain { .init(replica: replica) }
  }
  let config: ExampleConfiguration
  let session: AuthSession
  private let savedSession: any SessionStore
  private let profiles: PersonalProfiles
  private let fileURL: URL
  private let transport: any HTTPTransport
  private let guestCredentials: any GuestSessionStore
  private let socketFactory: WebSocketFactory
  @ObservationIgnored private var current: Runtime?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var observing: Task<Void, Never>?
  @ObservationIgnored private var aiTask: Task<Void, Never>?
  @ObservationIgnored private var answer: CheckedContinuation<Bool, Never>?
  var rows: [ReplicaRecord] = []
  var models: [AIModelDescriptor] = []
  var uploads: [AIFileReference] = []
  var plan: ReplicaImportPlan?
  var confirmation: Confirmation?
  var error: String?
  var profileLabel = "Opening local data"
  var viewID = UUID()
  var ready = false
  var runningAI = false
  var syncing = false
  var streamingText = ""
  private var deferredImport = false
  private var connected = false
  private var foreground = true
  var isGuest: Bool { current?.userID == nil }
  var canSync: Bool { current?.authenticated == true }
  var domain: PersonalDomain? { current?.domain }
  init(
    config: ExampleConfiguration, session: AuthSession, savedSession: any SessionStore,
    profiles: PersonalProfiles = .shared,
    fileURL: URL = URL.applicationSupportDirectory.appending(path: "MMGTExample/personal.sqlite"),
    transport: any HTTPTransport = URLSessionTransport(),
    guestCredentials: any GuestSessionStore = KeychainGuestSessionStore(),
    socketFactory: @escaping WebSocketFactory = { try URLSessionWebSocketConnection(url: $0) }
  ) {
    self.config = config
    self.session = session
    self.savedSession = savedSession
    self.profiles = profiles
    self.fileURL = fileURL
    self.transport = transport
    self.guestCredentials = guestCredentials
    self.socketFactory = socketFactory
  }
  private func check(_ expected: UUID) throws {
    try Task.checkCancellation()
    guard expected == generation else { throw MMGTError.sessionChanged }
  }
  func perform(viewID expectedView: UUID? = nil, _ action: () async throws -> Void) async {
    guard expectedView == nil || expectedView == viewID, !Task.isCancelled else { return }
    let expected = generation
    error = nil
    do { try await action() } catch is CancellationError {} catch {
      if expected == generation || !ready { self.error = Self.message(error) }
    }
  }
  static func message(_ error: any Error) -> String {
    let code = (error as? APIError)?.code ?? (error as? GuestSessionError)?.code
    switch code {
    case "guest_disabled":
      return
        "Guest AI is disabled. Your local data still works; the app owner can enable access in Panel."
    case "guest_limit_exceeded":
      return "The AI allowance or concurrency limit was reached. No generation was retried."
    case "guest_model_forbidden":
      return "This model is no longer allowed. Reload the catalog and choose explicitly."
    case "guest_session_expired":
      return "The AI session expired. Start a new AI session; local data remains saved."
    case "guest_unavailable":
      return "Guest AI is temporarily unavailable. Local data remains available."
    default: return (error as? APIError)?.message ?? String(describing: error)
    }
  }
  /// A previously confirmed, locally activated Keychain identity may open its local replica offline.
  /// It supplies no cloud access until Auth restore/login confirms the account again.
  func restoreLocal() async throws {
    guard current == nil else { return }
    let cached = try savedSession.load()
    if let cached,
      cached.identity.environment != (try config.service(config.authURL)).storagePartition
    {
      throw MMGTError.sessionChanged
    }
    try await open(userID: cached?.identity.userID, tokenProvider: nil)
  }
  func bindAccount(_ identity: AccountIdentity) async throws {
    if current?.userID == identity.userID, current?.authenticated == true { return }
    guard await session.identity == identity else { throw MMGTError.sessionChanged }
    // Attach before opening asynchronous local resources, so a concurrent logout cancels
    // this coordinator as well as clients that were already fully constructed.
    await session.attach(self)
    guard await session.identity == identity else { throw MMGTError.sessionChanged }
    let source = await session.tokenProvider
    try await open(userID: identity.userID, tokenProvider: source)
    let expected = generation
    guard await session.identity == identity else {
      if generation == expected { await activityChanged(.signedOut) }
      throw MMGTError.sessionChanged
    }
    try check(expected)
  }
  private func open(userID: String?, tokenProvider: AccessTokenProvider?) async throws {
    generation = UUID()
    let expected = generation
    await closeRuntime()
    try check(expected)
    let configuration = try config.service(config.syncURL)
    let disk = try SQLiteSyncStore(fileURL: fileURL)
    var profileID = try await profiles.guest(configuration: configuration)
    try check(expected)
    func guestReplica(_ id: String) throws -> LocalReplica {
      try .init(
        identity: .init(configuration: configuration, principal: .guest(id)),
        collections: PersonalDomain.collections, store: disk, validate: PersonalDomain.validate)
    }
    var guest = try guestReplica(profileID)
    if userID == nil, try await guest.snapshot().metadata.adoptedImportID != nil {
      await guest.close()
      profileID = try await profiles.guest(configuration: configuration, replacing: profileID)
      try check(expected)
      guest = try guestReplica(profileID)
    }
    let replica =
      try userID.map {
        try LocalReplica(
          identity: .init(configuration: configuration, principal: .user($0)),
          collections: PersonalDomain.collections, store: disk, validate: PersonalDomain.validate)
      } ?? guest
    let guestSession = try GuestSession(
      configuration: config.service(config.authURL), profileID: profileID, store: guestCredentials,
      transport: transport)
    let source: AccessTokenProvider
    if userID == nil {
      source = await guestSession.tokenProvider
    } else {
      source = tokenProvider ?? { throw MMGTError.unauthenticated }
    }
    let ai = AIClient(
      configuration: try config.service(config.aiURL), tokenProvider: source, transport: transport,
      socketFactory: socketFactory)
    do {
      let snapshot = try await replica.snapshot()
      try check(expected)
      current = Runtime(
        guest: guest, replica: replica, guestSession: guestSession, ai: ai, userID: userID,
        authenticated: tokenProvider != nil)
      rows = snapshot.records.filter { !$0.deleted }
      profileLabel =
        userID.map {
          "Account \($0)" + (tokenProvider == nil ? " · local access, sign in to sync" : "")
        } ?? "Guest · this device"
      error = nil
      ready = true
      observe()
    } catch {
      await guest.close()
      await replica.close()
      await guestSession.close()
      await ai.close()
      throw error
    }
  }
  private func observe() {
    observing?.cancel()
    guard foreground, let current else { return }
    let expected = generation
    observing = Task { [weak self] in
      do {
        for try await snapshot in await current.replica.changes() {
          guard let self else { return }
          try self.check(expected)
          self.rows = snapshot.records.filter { !$0.deleted }
        }
      } catch {
        if !Task.isCancelled, let self, self.generation == expected {
          self.error = Self.message(error)
        }
      }
    }
  }
  private func closeRuntime() async {
    let old = current
    viewID = UUID()
    current = nil
    ready = false
    rows = []
    models = []
    uploads = []
    plan = nil
    connected = false
    syncing = false
    deferredImport = false
    streamingText = ""
    observing?.cancel()
    observing = nil
    cancelAI()
    runningAI = false
    if let old {
      await old.ai.close()
      await old.guestSession.close()
      await old.replica.close()
      await old.guest.close()
    }
  }
  func synchronize() async throws {
    guard let current, current.authenticated, !syncing, plan?.committed != false else { return }
    let expected = generation
    syncing = true
    defer { if generation == expected { syncing = false } }
    if !connected {
      let source = await session.tokenProvider
      try check(expected)
      guard await session.identity?.userID == current.userID else { throw MMGTError.sessionChanged }
      try await current.replica.connect(tokenProvider: source, transport: transport)
      try check(expected)
      connected = true
    }
    try await syncAccount(current, expected: expected)
    let source = try await current.guest.snapshot()
    if !deferredImport, source.metadata.adoptedImportID == nil,
      source.records.contains(where: { !$0.deleted })
    {
      let preview = try await current.guest.prepareImport(to: current.replica)
      try check(expected)
      plan = preview
      if !preview.requiresConfirmation {
        try await approveImport(choices: [:])
        try await syncAccount(current, expected: expected)
      }
    }
  }
  private func syncAccount(_ current: Runtime, expected: UUID) async throws {
    for _ in 0..<100 {
      let result = try await current.replica.synchronize()
      try check(expected)
      if !result.hasMore || (result.pushed == 0 && result.pulled == 0) { return }
    }
  }
  func approveImport(choices: [ReplicaRecordKey: ReplicaImportAction]) async throws {
    guard let current, let plan else { throw ReplicaError.importChanged }
    let expected = generation
    let result = try await current.guest.approveImport(
      plan.id, to: current.replica, confirmed: plan.requiresConfirmation,
      decisions: PersonalDomain.importDecisions(plan, choices: choices))
    try check(expected)
    self.plan = result
  }
  func deferImport() {
    deferredImport = true
    plan = nil
  }
  func reviewImport() async throws {
    deferredImport = false
    plan = nil
    try await synchronize()
  }
  func resolve(_ row: ReplicaRecord, keepLocal: Bool) async throws {
    guard let current, let issue = row.issues.first else { return }
    let replacement =
      keepLocal ? ReplicaIntent(key: row.key, data: row.data, deleted: row.deleted) : nil
    try await current.replica.resolveIssue(
      issue.entry.mutation.mutationId, replacement: replacement)
  }
  func loadModels() async throws {
    guard let current else { return }
    let expected = generation
    let catalog = try await current.ai.catalog()
    try check(expected)
    models = catalog.models.filter(\.enabled)
    if models.isEmpty {
      throw MMGTError.invalidConfiguration(
        "No AI model is available. Configure guest access in Panel.")
    }
  }
  func restartGuestAI() async throws {
    guard let current, current.userID == nil else { throw MMGTError.unauthenticated }
    try await current.guestSession.startNewSession()
    try await loadModels()
  }
  func upload(_ url: URL) async throws {
    guard let current else { return }
    let expected = generation
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let info = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
    guard let size = info.fileSize, size > 0, size <= 25 * 1024 * 1024 else {
      throw MMGTError.invalidConfiguration(
        "Choose a file of 1 byte to 25 MiB; the server may enforce a smaller allowance")
    }
    let data = try Data(contentsOf: url)
    guard data.count <= 25 * 1024 * 1024 else {
      throw MMGTError.invalidConfiguration("The file grew beyond the local upload bound")
    }
    let result = try await current.ai.upload(
      data: data, filename: url.lastPathComponent,
      contentType: info.contentType?.preferredMIMEType ?? "application/octet-stream")
    try check(expected)
    uploads.append(result)
  }
  func removeUpload(_ id: String) async throws {
    guard let current else { return }
    let expected = generation
    try await current.ai.deleteFile(id)
    try check(expected)
    uploads.removeAll { $0.id == id }
  }
  func ask(_ text: String, model: AIModelDescriptor) {
    guard let current, !runningAI, !text.isEmpty, text.utf16.count <= 20_000,
      models.contains(model)
    else { return }
    let expected = generation
    let attachments = uploads
    runningAI = true
    error = nil
    streamingText = ""
    aiTask = Task { [weak self] in
      guard let self else { return }
      let requestID = UUID().uuidString
      let userID = UUID().uuidString
      let replyID = UUID().uuidString
      let now = PersonalDomain.stamp()
      var saved = false
      defer {
        if generation == expected {
          runningAI = false
          streamingText = ""
          aiTask = nil
        }
      }
      do {
        try check(expected)
        let history = try await current.replica.list(collection: "personal_chat_messages")
          .filter { $0.data?["status"]?.string == "completed" }
          .sorted {
            ($0.data?["createdAt"]?.string ?? "", $0.key.id) < (
              $1.data?["createdAt"]?.string ?? "", $1.key.id
            )
          }.suffix(20)
          .map {
            AIInputItem(
              role: $0.data?["role"]?.string ?? "user",
              content: [.text($0.data?["text"]?.string ?? "")])
          }
        try await current.replica.transaction { tx in
          try tx.upsert(
            collection: "personal_chat_messages", id: userID,
            data: Self.chatEntry(role: "user", text: text, status: "completed", date: now))
          try tx.upsert(
            collection: "personal_chat_messages", id: replyID,
            data: Self.chatEntry(role: "assistant", text: "", status: "pending", date: now))
        }
        saved = true
        try check(expected)
        let parts: [AIContentPart] =
          [.text(text)]
          + attachments.map {
            $0.contentType.hasPrefix("image/") ? .image(fileID: $0.id) : .file(fileID: $0.id)
          }
        let result = try await current.ai.runTools(
          .init(
            connectionId: model.connectionId, model: model.id,
            systemPrompt:
              "Help with personal lists, tasks and notes. Read only the data needed. Local changes need confirmation; never claim a change succeeded before its tool result. Uploaded files are temporary.",
            input: Array(history) + [.init(role: "user", content: parts)],
            tools: PersonalDomain.toolDefinitions),
          tools: current.domain.tools(
            requestID: requestID,
            confirm: { [weak self] message in
              await self?.requestConfirmation(message, expected: expected) ?? false
            }), maxIterations: 8,
          onEvent: { [weak self] event in try await self?.receive(event, expected: expected) })
        try check(expected)
        let final = String((result.text ?? streamingText).prefix(40_000))
        try await current.replica.upsert(
          collection: "personal_chat_messages", id: replyID,
          data: Self.chatEntry(role: "assistant", text: final, status: "completed", date: now))
        try check(expected)
        uploads = []
      } catch {
        guard generation == expected else { return }
        let partial = streamingText
        // A fresh local task can save the partial reply even when the network task was cancelled.
        // It remains fenced to this original profile; switching accounts closes that replica.
        if saved {
          await Task { @MainActor in
            guard generation == expected else { return }
            do {
              try await current.replica.upsert(
                collection: "personal_chat_messages", id: replyID,
                data: Self.chatEntry(
                  role: "assistant", text: partial, status: "interrupted", date: now))
            } catch { if generation == expected { self.error = Self.message(error) } }
          }.value
        }
        if !(error is CancellationError), generation == expected {
          self.error = Self.message(error)
        }
      }
    }
  }
  private nonisolated static func chatEntry(
    role: String, text: String, status: String, date: String
  ) -> JSONValue {
    [
      "conversationId": "main", "role": .string(role), "text": .string(text),
      "status": .string(status), "createdAt": .string(date),
      "updatedAt": .string(PersonalDomain.stamp()),
    ]
  }
  private func receive(_ event: AIStreamEvent, expected: UUID) throws {
    try check(expected)
    if case .textDelta(let text) = event {
      guard streamingText.utf16.count + text.utf16.count <= 40_000 else {
        throw MMGTError.bufferOverflow
      }
      streamingText += text
    }
  }
  private func requestConfirmation(_ message: String, expected: UUID) async -> Bool {
    guard generation == expected, !Task.isCancelled, confirmation == nil else { return false }
    let id = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        answer = continuation
        confirmation = .init(id: id, message: message)
      }
    } onCancel: {
      Task { @MainActor [weak self] in if self?.confirmation?.id == id { self?.decide(false) } }
    }
  }
  func decide(_ accepted: Bool) {
    let pending = answer
    answer = nil
    confirmation = nil
    pending?.resume(returning: accepted)
  }
  func cancelAI() {
    aiTask?.cancel()
    decide(false)
  }
  func activityChanged(_ activity: ApplicationActivity) async {
    if activity == .signedOut {
      generation = UUID()
      let expected = generation
      await closeRuntime()
      guard generation == expected else { return }
      await perform { try await restoreLocal() }
    } else if activity == .background || activity == .inactive {
      foreground = false
      observing?.cancel()
      observing = nil
      cancelAI()
      if let current {
        await current.replica.activityChanged(.background)
        await current.guest.activityChanged(.background)
        await current.guestSession.activityChanged(.background)
        await current.ai.activityChanged(.background)
      }
    } else if activity == .active {
      foreground = true
      if current == nil { await perform { try await restoreLocal() } }
      observe()
    }
  }
}
