// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "QAWorkbench",
  platforms: [.macOS(.v15)],
  dependencies: [
    .package(path: "../Packages/WBCore"),
    .package(path: "../Packages/WBProcess"),
    .package(path: "../Packages/WBDevices"),
    .package(path: "../Packages/WBMirror"),
    .package(path: "../Packages/WBInspect"),
    .package(path: "../Packages/WBFlutter"),
    .package(path: "../Packages/WBNetwork"),
    .package(path: "../Packages/WBVision"),
    .package(path: "../Packages/WBSnapshot"),
  ],
  targets: [
    .executableTarget(
      name: "QAWorkbench",
      dependencies: [
        .product(name: "WBCore", package: "WBCore"),
        .product(name: "WBProcess", package: "WBProcess"),
        .product(name: "WBDevices", package: "WBDevices"),
        .product(name: "WBMirror", package: "WBMirror"),
        .product(name: "WBInspect", package: "WBInspect"),
        .product(name: "WBFlutter", package: "WBFlutter"),
        .product(name: "WBNetwork", package: "WBNetwork"),
        .product(name: "WBVision", package: "WBVision"),
        .product(name: "WBSnapshot", package: "WBSnapshot"),
      ]
    )
  ],
  swiftLanguageModes: [.v6]
)
