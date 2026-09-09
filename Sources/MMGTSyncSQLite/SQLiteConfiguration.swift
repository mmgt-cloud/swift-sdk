import Foundation
import GRDB

public struct SQLiteConfiguration: Sendable {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }
}
