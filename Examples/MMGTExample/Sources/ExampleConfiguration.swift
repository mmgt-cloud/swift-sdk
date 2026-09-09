import Foundation
import MMGTCore

struct ExampleConfiguration: Decodable, Sendable {
  let appID: String
  let authURL: URL
  let billingURL: URL
  let realtimeURL: URL
  let syncURL: URL
  let aiURL: URL
  let oidcClientID: String
  let redirectURL: URL
  let relyingPartyID: String
  let syncCollection: String
  let developmentScheme: Bool
  var isConfigured: Bool {
    appID != "YOUR_APP_ID" && !(authURL.host?.hasSuffix(".invalid") ?? true)
  }
  func service(_ url: URL) throws -> ServiceConfiguration { try .init(baseURL: url, appID: appID) }
  static func load() throws -> Self {
    guard
      let url = Bundle.main.url(forResource: "Configuration", withExtension: "json")
        ?? Bundle.main.url(forResource: "Configuration.sample", withExtension: "json")
    else {
      throw MMGTError.invalidConfiguration(
        "Add the public application configuration to the example")
    }
    return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
  }
}
