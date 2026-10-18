// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "WBProcess",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "WBProcess", targets: ["WBProcess"])
  ],
  dependencies: [
    .package(path: "../WBCore")
  ],
  targets: [
    .target(
      name: "WBProcess",
      dependencies: [
        .product(name: "WBCore", package: "WBCore")
      ]
    ),
    .testTarget(
      name: "WBProcessTests",
      dependencies: ["WBProcess"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
