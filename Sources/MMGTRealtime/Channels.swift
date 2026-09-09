import Foundation
import MMGTCore

public enum RealtimeChannels {
  public static func user(_ id: String) -> String { "user:\(id)" }
  public static func validate(_ channel: String) throws {
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:/-")
    guard !channel.isEmpty, channel.utf8.count <= 128,
      channel.unicodeScalars.allSatisfy(allowed.contains),
      !channel.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
        $0.isEmpty || $0 == "." || $0 == ".."
      })
    else {
      throw MMGTError.invalidConfiguration("Invalid Realtime channel")
    }
  }
}
