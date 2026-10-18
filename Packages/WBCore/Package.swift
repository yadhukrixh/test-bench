// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "WBCore",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "WBCore", targets: ["WBCore"])
  ],
  targets: [
    .target(name: "WBCore"),
    .testTarget(name: "WBCoreTests", dependencies: ["WBCore"]),
  ],
  swiftLanguageModes: [.v6]
)
