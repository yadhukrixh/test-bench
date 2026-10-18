// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "WBSnapshot",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "WBSnapshot", targets: ["WBSnapshot"])
  ],
  targets: [
    .target(name: "WBSnapshot"),
    .testTarget(
      name: "WBSnapshotTests",
      dependencies: ["WBSnapshot"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
