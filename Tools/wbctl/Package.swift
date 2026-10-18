// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "wbctl",
  platforms: [.macOS(.v15)],
  dependencies: [
    .package(path: "../../Packages/WBCore"),
    .package(path: "../../Packages/WBProcess"),
    .package(path: "../../Packages/WBDevices"),
  ],
  targets: [
    .executableTarget(
      name: "wbctl",
      dependencies: [
        .product(name: "WBCore", package: "WBCore"),
        .product(name: "WBProcess", package: "WBProcess"),
        .product(name: "WBDevices", package: "WBDevices"),
      ]
    )
  ],
  swiftLanguageModes: [.v6]
)
