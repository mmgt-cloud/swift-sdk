import SwiftUI

/// A fresh acceptance consumer with no account restoration or network tasks.
/// The companion test runs the actual SDK and SQLite while iOS has no network path.
@main struct OfflineHost: App {
  var body: some Scene {
    WindowGroup {
      Text("MMGT offline acceptance")
        .accessibilityIdentifier("offline-acceptance-host")
    }
  }
}
