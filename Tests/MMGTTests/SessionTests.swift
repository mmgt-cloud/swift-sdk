import Foundation
import Synchronization
import Testing
import MMGTCore
import MMGTAuth

final class TestSessionStore: SessionStore, Sendable {
    let state = Mutex<PersistedSession?>(nil)
    func load() -> PersistedSession? { state.withLock { $0 } }
    func save(_ session: PersistedSession) { state.withLock { $0 = session } }
    func clear() { state.withLock { $0 = nil } }
}

actor ControlledTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var pending: [Int: CheckedContinuation<HTTPResponse, any Error>] = [:]
    var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let index = requests.count
        requests.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            let ready = observers.filter { $0.0 < requests.count }
            observers.removeAll { $0.0 < requests.count }
            for (_, observer) in ready { observer.resume() }
        }
    }
    func waitForRequest(_ index: Int) async {
        if requests.count > index { return }
        await withCheckedContinuation { observers.append((index, $0)) }
    }
    func reply(_ index: Int, _ body: String, status: Int = 200) {
        pending.removeValue(forKey: index)?.resume(returning: .init(data: Data(body.utf8), status: status))
    }
}

private let profileFixture = #"{"id":"user-a","email":"a@example.invalid","email_verified":true,"two_fa_enabled":false,"has_password":true,"created_at":"2026-09-09T12:00:00.123456Z","updated_at":"2026-09-09T12:00:00Z"}"#

@Suite(.timeLimit(.minutes(1))) struct SessionTests {
    func fixture() throws -> (AuthSession, TestSessionStore, ControlledTransport) {
        let configuration = try ServiceConfiguration(baseURL: URL(string:"https://auth.example.invalid/auth")!, appID:"app-a")
        let store = TestSessionStore()
        let transport = ControlledTransport()
        return (AuthSession(configuration: configuration, store: store, transport: transport), store, transport)
    }
    @Test func profileReturningAfterLogoutCannotRestoreAccount() async throws {
        let (session, store, transport) = try fixture()
        let login = Task { try await session.authenticate { _ in .authenticated(.init(accessToken:"test-access",refreshToken:"test-refresh")) } }
        await transport.waitForRequest(0)
        try await session.signOutLocally()
        await transport.reply(0, profileFixture)
        await #expect(throws: MMGTError.sessionChanged) { try await login.value }
        #expect(store.load() == nil)
        #expect(await session.identity == nil)
    }
    @Test func lateRefreshCannotRestoreAccountOrKeychain() async throws {
        let (session, store, transport) = try fixture()
        let login = Task { try await session.authenticate { _ in .authenticated(.init(accessToken:"old-access",refreshToken:"old-refresh")) } }
        await transport.waitForRequest(0)
        await transport.reply(0, profileFixture)
        _ = try await login.value
        let refresh = Task { try await session.refreshToken() }
        await transport.waitForRequest(1)
        try await session.signOutLocally()
        await transport.reply(1, #"{"access_token":"late-access","refresh_token":"late-refresh"}"#)
        do { _ = try await refresh.value; Issue.record("Late refresh succeeded") } catch { }
        #expect(store.load() == nil)
        #expect(await session.identity == nil)
    }
    @Test func restoreRejectsAnotherAccount() async throws {
        let (session, store, transport) = try fixture()
        let identity = try AccountIdentity(configuration: session.configuration, userID:"different-user")
        store.save(.init(identity:identity,tokens:.init(accessToken:"test-access",refreshToken:"test-refresh")))
        let restore = Task { try await session.restore() }
        await transport.waitForRequest(0)
        await transport.reply(0, profileFixture)
        await #expect(throws: MMGTError.sessionChanged) { try await restore.value }
        #expect(await session.identity == nil)
    }
}
