// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "WBDevices",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "WBDevices", targets: ["WBDevices"])
  ],
  dependencies: [
    .package(path: "../WBCore"),
    .package(path: "../WBProcess"),
    .package(path: "../WBTestSupport"),
  ],
  targets: [
    .target(
      name: "WBDevices",
      dependencies: [
        .product(name: "WBCore", package: "WBCore"),
        .product(name: "WBProcess", package: "WBProcess"),
      ]
    ),
    .testTarget(
      name: "WBDevicesTests",
      dependencies: [
        "WBDevices",
        .product(name: "WBTestSupport", package: "WBTestSupport"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
