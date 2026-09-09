import Foundation

public protocol WebSocketConnection: Sendable {
    func send(_ message: JSONValue) async throws
    func receive() async throws -> JSONValue
    func close() async
}

public typealias WebSocketFactory = @Sendable (URL) throws -> any WebSocketConnection

/// A single socket, without reconnect or application-message retry.
public final class URLSessionWebSocketConnection: WebSocketConnection, Sendable {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    public init(url: URL) throws {
        guard url.scheme == "wss", url.user == nil, url.password == nil, url.query == nil else {
            throw MMGTError.invalidConfiguration("WebSocket requires WSS without URL credentials")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil; configuration.urlCache = nil
        session = URLSession(configuration:configuration,delegate:WebSocketRedirectDelegate(),delegateQueue:nil)
        socket = session.webSocketTask(with:url)
        socket.maximumMessageSize = 4 * 1024 * 1024
        socket.resume()
    }
    public func send(_ message: JSONValue) async throws {
        try Task.checkCancellation()
        let data=try JSONEncoder().encode(message)
        guard let text=String(data:data,encoding:.utf8) else { throw MMGTError.invalidResponse("Invalid JSON encoding") }
        try await socket.send(.string(text))
        try Task.checkCancellation()
    }
    public func receive() async throws -> JSONValue {
        let message=try await socket.receive()
        try Task.checkCancellation()
        let data:Data
        switch message {
        case .data(let bytes): data=bytes
        case .string(let text): data=Data(text.utf8)
        @unknown default: throw MMGTError.invalidResponse("Unsupported WebSocket message")
        }
        return try JSONDecoder().decode(JSONValue.self,from:data)
    }
    public func close() {
        socket.cancel(with:.normalClosure,reason:nil)
        session.invalidateAndCancel()
    }
    deinit { socket.cancel(with:.goingAway,reason:nil); session.invalidateAndCancel() }
}

private final class WebSocketRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

extension ServiceConfiguration {
    public func webSocketURL(_ path: [String]) throws -> URL {
        var parts=URLComponents(url:try url(path),resolvingAgainstBaseURL:false)!
        parts.scheme="wss"
        return parts.url!
    }
}
