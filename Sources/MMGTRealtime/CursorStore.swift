import Foundation
import CryptoKit
import Darwin
import MMGTCore

public struct RealtimeCursor: Codable, Sendable, Equatable {
    public let revision: String
    public let eventID: String?
    public init(revision: String = "0", eventID: String? = nil) { self.revision=revision; self.eventID=eventID }
}

public protocol RealtimeCursorStore: Sendable {
    func load(identity: AccountIdentity, channel: String) async throws -> RealtimeCursor
    func compareAndSet(identity: AccountIdentity, channel: String, expected: RealtimeCursor, eventID: String?) async throws -> RealtimeCursor?
}

public actor MemoryRealtimeCursorStore: RealtimeCursorStore {
    private var values:[AccountIdentity:[String:RealtimeCursor]]=[:]
    public init() {}
    public func load(identity: AccountIdentity, channel: String) -> RealtimeCursor { values[identity]?[channel] ?? .init() }
    public func compareAndSet(identity: AccountIdentity, channel: String, expected: RealtimeCursor, eventID: String?) -> RealtimeCursor? {
        guard load(identity:identity,channel:channel) == expected else { return nil }
        let next=RealtimeCursor(revision:UUID().uuidString,eventID:eventID)
        values[identity,default:[:]][channel]=next
        return next
    }
}

/// Persist confirmed cursors only. The lock is held through atomic replacement across store instances/processes.
public final class FileRealtimeCursorStore: RealtimeCursorStore, Sendable {
    private let file:URL
    public init(fileURL: URL) throws {
        guard fileURL.isFileURL else { throw MMGTError.invalidConfiguration("Cursor store requires a local URL") }
        try FileManager.default.createDirectory(at:fileURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        file=fileURL
    }
    private func key(_ identity: AccountIdentity, _ channel: String) throws -> String {
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
        var data=try encoder.encode(identity); data.append(0); data.append(Data(channel.utf8))
        return SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    }
    private func locked<T>(_ body: (inout [String:RealtimeCursor]) throws -> (T,Bool)) throws -> T {
        let descriptor=Darwin.open(file.path+".lock",O_CREAT|O_RDWR,S_IRUSR|S_IWUSR)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        while flock(descriptor,LOCK_EX) != 0 { if errno != EINTR { throw CocoaError(.fileWriteUnknown) } }
        defer { flock(descriptor,LOCK_UN) }
        var values:[String:RealtimeCursor]=[:]
        if FileManager.default.fileExists(atPath:file.path) { values=try JSONDecoder().decode([String:RealtimeCursor].self,from:Data(contentsOf:file)) }
        let (result,changed)=try body(&values)
        if changed { try JSONEncoder().encode(values).write(to:file,options:[.atomic,.completeFileProtection]) }
        return result
    }
    public func load(identity: AccountIdentity, channel: String) async throws -> RealtimeCursor {
        let key=try key(identity,channel)
        return try locked { ($0[key] ?? .init(),false) }
    }
    public func compareAndSet(identity: AccountIdentity, channel: String, expected: RealtimeCursor, eventID: String?) async throws -> RealtimeCursor? {
        let key=try key(identity,channel)
        return try locked { values in
            guard (values[key] ?? .init()) == expected else { return (nil,false) }
            let next=RealtimeCursor(revision:UUID().uuidString,eventID:eventID)
            values[key]=next
            return (next,true)
        }
    }
}
