// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "WBFlutter",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "WBFlutter", targets: ["WBFlutter"])
  ],
  dependencies: [
    .package(path: "../WBCore"),
    .package(path: "../WBProcess"),
  ],
  targets: [
    .target(
      name: "WBFlutter",
      dependencies: [
        .product(name: "WBCore", package: "WBCore"),
        .product(name: "WBProcess", package: "WBProcess"),
      ]
    ),
    .testTarget(
      name: "WBFlutterTests",
      dependencies: ["WBFlutter"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
