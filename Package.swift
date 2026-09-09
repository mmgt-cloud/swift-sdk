// swift-tools-version: 6.2
import PackageDescription

let modules = [
  "MMGTCore", "MMGTAuth", "MMGTBilling", "MMGTRealtime", "MMGTSync", "MMGTSyncSQLite", "MMGTAI",
  "MMGTSwiftUI",
]
let package = Package(
  name: "MMGT",
  platforms: [.iOS(.v26)],
  products: modules.map { .library(name: $0, targets: [$0]) },
  dependencies: [
    .package(url: "https://github.com/openid/AppAuth-iOS.git", from: "3.0.0"),
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
  ],
  targets: [
    .target(name: "MMGTCore"),
    .target(
      name: "MMGTAuth",
      dependencies: ["MMGTCore", .product(name: "AppAuth", package: "AppAuth-iOS")]),
    .target(name: "MMGTBilling", dependencies: ["MMGTCore"]),
    .target(name: "MMGTRealtime", dependencies: ["MMGTCore"]),
    .target(name: "MMGTSync", dependencies: ["MMGTCore"]),
    .target(
      name: "MMGTSyncSQLite",
      dependencies: ["MMGTSync", .product(name: "GRDB", package: "GRDB.swift")]),
    .target(name: "MMGTAI", dependencies: ["MMGTCore"]),
    .target(name: "MMGTSwiftUI", dependencies: ["MMGTCore"]),
    .testTarget(
      name: "MMGTTests", dependencies: modules.map { .byName(name: $0) },
      resources: [.copy("Fixtures")]),
  ],
  swiftLanguageModes: [.v6]
)
