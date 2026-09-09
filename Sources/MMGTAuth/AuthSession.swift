import Foundation
import MMGTCore

/// Own one instance per active application session and share its token provider with the service clients.
public actor AuthSession: ApplicationLifecycleParticipant {
    public nonisolated let configuration: ServiceConfiguration
    private let transport: any HTTPTransport
    private let store: any SessionStore
    private var current: PersistedSession?
    private var generation = UUID()
    private var refresh: (id: UUID, task: Task<AuthTokens, any Error>)?
    private var login: (id: UUID, task: Task<LoginResult, any Error>)?
    private var participants: [any ApplicationLifecycleParticipant] = []
    public private(set) var user: UserResponse?

    public init(configuration: ServiceConfiguration, store: (any SessionStore)? = nil, transport: any HTTPTransport = URLSessionTransport()) {
        self.configuration = configuration; self.store = store ?? KeychainSessionStore(configuration: configuration); self.transport = transport
    }
    public nonisolated var tokenProvider: AccessTokenProvider { { try await self.accessToken() } }
    public var identity: AccountIdentity? { current?.identity }
    public func attach(_ participant: any ApplicationLifecycleParticipant) { participants.append(participant) }
    public func accessToken() throws -> String {
        guard let token = current?.tokens.accessToken else { throw MMGTError.unauthenticated }
        return token
    }

    public func restore() async throws {
        let expected = generation
        guard let saved = try store.load() else { return }
        let profile = try await client(token: saved.tokens.accessToken).getProfile()
        guard expected == generation, profile.id == saved.identity.userID else { throw MMGTError.sessionChanged }
        current = saved; user = profile
    }

    /// All native/password/MFA login methods can be supplied here; late results cannot restore a logged-out session.
    public func authenticate(_ operation: @escaping @Sendable (AuthClient) async throws -> LoginResult) async throws -> LoginResult {
        let (expected, deletion) = resetState()
        for participant in participants { await participant.activityChanged(.signedOut) }
        try deletion.get()
        guard generation == expected else { throw MMGTError.sessionChanged }
        let client = client()
        let task = Task { try await operation(client) }
        login = (expected, task)
        defer { if login?.id == expected { login = nil } }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard generation == expected else { throw MMGTError.sessionChanged }
        let tokens: AuthTokens
        switch result {
        case .authenticated(let value), .requiresTwoFactorSetup(let value, _): tokens = value
        default: return result
        }
        let profile = try await self.client(token: tokens.accessToken).getProfile()
        guard generation == expected else { throw MMGTError.sessionChanged }
        let session = PersistedSession(identity: try AccountIdentity(configuration: configuration, userID: profile.id), tokens: tokens)
        try store.save(session)
        current = session; user = profile
        return result
    }

    /// Explicit single-flight refresh. Generations are checked after every suspension, including shared refresh completion.
    public func refreshToken() async throws -> AuthTokens {
        guard let old = current else { throw MMGTError.unauthenticated }
        let expected = generation
        let flight: (id: UUID, task: Task<AuthTokens, any Error>)
        if let refresh { flight = refresh }
        else {
            let client = client()
            flight = (UUID(), Task { try await client.refreshToken(old.tokens.refreshToken) })
            refresh = flight
        }
        do {
            let tokens = try await flight.task.value
            guard expected == generation else { throw MMGTError.sessionChanged }
            if refresh?.id == flight.id {
                let value = PersistedSession(identity: old.identity, tokens: tokens)
                try store.save(value)
                current = value; refresh = nil
            }
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
        let (_, deletion) = resetState()
        for participant in participants { await participant.activityChanged(.signedOut) }
        try deletion.get()
    }
    private func resetState() -> (UUID, Result<Void, any Error>) {
        generation = UUID()
        refresh?.task.cancel(); refresh = nil
        login?.task.cancel(); login = nil
        current = nil; user = nil
        // Close every service even if Keychain is locked and deletion fails.
        return (generation, Result { try store.clear() })
    }
    public func activityChanged(_ activity: ApplicationActivity) async {
        for participant in participants { await participant.activityChanged(activity) }
    }
    private func client(token: String? = nil) -> AuthClient {
        AuthClient(configuration: configuration, tokenProvider: token.map { value in { @Sendable in value } }, transport: transport)
    }
}
