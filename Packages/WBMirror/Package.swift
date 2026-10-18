// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "WBMirror",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "WBMirror", targets: ["WBMirror"])
  ],
  dependencies: [
    .package(path: "../WBCore"),
    .package(path: "../WBProcess"),
  ],
  targets: [
    .target(
      name: "WBMirror",
      dependencies: [
        .product(name: "WBCore", package: "WBCore"),
        .product(name: "WBProcess", package: "WBProcess"),
      ]
    ),
    .testTarget(
      name: "WBMirrorTests",
      dependencies: ["WBMirror"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
