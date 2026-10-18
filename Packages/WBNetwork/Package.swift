// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "WBNetwork",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "WBNetwork", targets: ["WBNetwork"])
  ],
  dependencies: [
    .package(path: "../WBCore"),
    .package(path: "../WBFlutter"),
    .package(path: "../WBProcess"),
  ],
  targets: [
    .target(
      name: "WBNetwork",
      dependencies: [
        .product(name: "WBCore", package: "WBCore"),
        .product(name: "WBFlutter", package: "WBFlutter"),
        .product(name: "WBProcess", package: "WBProcess"),
      ]
    ),
    .testTarget(
      name: "WBNetworkTests",
      dependencies: [
        "WBNetwork",
        .product(name: "WBFlutter", package: "WBFlutter"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
