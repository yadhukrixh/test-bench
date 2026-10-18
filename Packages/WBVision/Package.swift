// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "WBVision",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "WBVision", targets: ["WBVision"])
  ],
  dependencies: [
    .package(path: "../WBCore"),
    .package(path: "../WBInspect"),
  ],
  targets: [
    .target(
      name: "WBVision",
      dependencies: [
        .product(name: "WBCore", package: "WBCore"),
        .product(name: "WBInspect", package: "WBInspect"),
      ]
    ),
    .testTarget(
      name: "WBVisionTests",
      dependencies: ["WBVision"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
