import Foundation
import MMGTCore

/// Public local IDs only. Credentials remain in the SDK's non-iCloud Keychain stores.
/// One actor serializes all example windows; extensions need their own coordinated repository.
actor PersonalProfiles {
  static let shared = PersonalProfiles(
    fileURL: URL.applicationSupportDirectory.appending(path: "MMGTExample/personal-profiles.json"))
  let fileURL: URL
  init(fileURL: URL) { self.fileURL = fileURL }
  func guest(configuration: ServiceConfiguration, replacing expected: String? = nil) throws
    -> String
  {
    var profiles: [String: String]
    do {
      profiles = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fileURL))
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile { profiles = [:] }
    let key = configuration.storagePartition
    if let current = profiles[key] {
      guard UUID(uuidString: current) != nil else {
        throw MMGTError.invalidConfiguration(
          "The saved local profile has invalid ownership; restore it before continuing")
      }
      if current != expected { return current }
    }
    let id = UUID().uuidString
    profiles[key] = id
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.complete])
    try JSONEncoder().encode(profiles).write(
      to: fileURL, options: [.atomic, .completeFileProtection])
    return id
  }
}
