import Foundation

// Xcode's application-hosted test bundle includes the same synthetic resources
// as the SPM test target. This file is not compiled into the package or example app.
private final class DeviceFixtureBundle: NSObject {}
extension Bundle {
  static let module = Bundle(for: DeviceFixtureBundle.self)
}
