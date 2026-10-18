// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "WBWeb",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "WBWeb", targets: ["WBWeb"])
  ],
  dependencies: [
    .package(path: "../WBCore"),
    .package(path: "../WBProcess"),
  ],
  targets: [
    .target(
      name: "WBWeb",
      dependencies: [
        .product(name: "WBCore", package: "WBCore"),
        .product(name: "WBProcess", package: "WBProcess"),
      ]
    ),
    .testTarget(
      name: "WBWebTests",
      dependencies: [
        "WBWeb",
        .product(name: "WBProcess", package: "WBProcess"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
