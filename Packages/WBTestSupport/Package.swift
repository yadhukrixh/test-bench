// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "WBTestSupport",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "WBTestSupport", targets: ["WBTestSupport"])
  ],
  dependencies: [
    .package(path: "../WBCore"),
    .package(path: "../WBProcess"),
  ],
  targets: [
    .target(
      name: "WBTestSupport",
      dependencies: [
        .product(name: "WBCore", package: "WBCore"),
        .product(name: "WBProcess", package: "WBProcess"),
      ]
    )
  ],
  swiftLanguageModes: [.v6]
)
