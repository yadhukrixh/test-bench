// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "WBInspect",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "WBInspect", targets: ["WBInspect"])
  ],
  dependencies: [
    .package(path: "../WBCore"),
    .package(path: "../WBProcess"),
  ],
  targets: [
    .target(
      name: "WBInspect",
      dependencies: [
        .product(name: "WBCore", package: "WBCore"),
        .product(name: "WBProcess", package: "WBProcess"),
      ]
    ),
    .testTarget(
      name: "WBInspectTests",
      dependencies: [
        "WBInspect",
        .product(name: "WBProcess", package: "WBProcess"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
