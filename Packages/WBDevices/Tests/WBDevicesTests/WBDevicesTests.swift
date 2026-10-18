import Darwin
import Foundation
import Testing
import WBProcess
import WBTestSupport

@testable import WBDevices

struct ParseTests {
  @Test func readsEmulatorSerials() {
    let text = """
      List of devices attached
      emulator-5554\tdevice
      emulator-5556\toffline
      """
    #expect(ADBText.emulatorSerials(in: text) == ["emulator-5554"])
    #expect(ADBText.consolePort(serial: "emulator-5554") == 5554)
    #expect(
      ADBText.foregroundPackage(
        in:
          "  mCurrentFocus=Window{fa4c97a u0 com.allright.lookmeal/com.allright.lookmeal.MainActivity}"
      ) == "com.allright.lookmeal")
    #expect(
      ADBText.packageAPKPaths(
        in: """
          package:/data/app/base.apk
          package:/data/app/split_config.arm64_v8a.apk
          """
      ) == ["/data/app/base.apk", "/data/app/split_config.arm64_v8a.apk"])
  }

  @Test func launchArgumentsMatchThePhase0Command() {
    #expect(
      EmulatorLaunch.arguments(avd: "Pixel_8", consolePort: 5554, grpcPort: 8554) == [
        "-avd", "Pixel_8",
        "-port", "5554",
        "-grpc", "8554",
        "-no-window",
        "-no-audio",
        "-no-boot-anim",
        "-crash-report-mode", "disabled",
      ]
    )
    #expect(EmulatorLaunch.grpcPort(forConsole: 5554) == 8554)
    #expect(EmulatorLaunch.chooseConsolePort(used: [5554]) == 5556)
  }

  @Test func parsesDiscoveryFields() {
    let text = """
      avd.id=Pixel_8
      port.serial=5554
      grpc.port=8554
      """
    let endpoint = EmulatorDiscovery.parse(text: text, pid: 42)
    #expect(endpoint?.avdID == "Pixel_8")
    #expect(endpoint?.serialPort == 5554)
    #expect(endpoint?.grpcPort == 8554)
  }

  @Test func readsBootedFromTheStatusMessage() {
    let body = Data([0x00, 0x00, 0x00, 0x00, 0x07, 0x0A, 0x01, 0x76, 0x10, 0x01, 0x18, 0x01])
    #expect(GrpcStatusMessage.booted(grpcBody: body) == true)
    let off = Data([0x00, 0x00, 0x00, 0x00, 0x02, 0x18, 0x00])
    #expect(GrpcStatusMessage.booted(grpcBody: off) == false)
  }

  @Test func readsSimulators() throws {
    let json = """
      {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-3":[
        {"udid":"AAA","name":"iPhone 17","state":"Shutdown","isAvailable":true},
        {"udid":"BBB","name":"Old","state":"Shutdown","isAvailable":false}
      ]}}
      """
    let devices = try SimctlCatalog.devices(from: Data(json.utf8))
    #expect(devices.map(\.id) == ["ios:AAA"])
    #expect(devices.first?.name == "iPhone 17")
  }
}

struct DeviceManagerTests {
  @Test func bootsAndStopsAStandInEmulator() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("emulator")
    try "#!/bin/sh\nsleep 30\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let supervisor = Supervisor(directory: root)
    let runner = ScriptedCommandRunner { call in
      if call.arguments.contains("devices") {
        return CommandResult(status: 0, stdout: "List of devices attached\n")
      }
      if call.arguments.contains("-list-avds") {
        return CommandResult(status: 0, stdout: "Pixel_8\n")
      }
      if call.arguments.contains("sys.boot_completed") {
        return CommandResult(status: 0, stdout: "1\n")
      }
      if call.arguments.contains("emu") {
        return CommandResult(status: 0, stdout: "OK\n")
      }
      return CommandResult(status: 1, stdout: "", stderr: call.arguments.joined(separator: " "))
    }
    let manager = DeviceManager(
      supervisor: supervisor,
      locator: MapLocator(files: ["emulator": script, "adb": URL(fileURLWithPath: "/bin/echo")]),
      runner: runner,
      status: AlwaysReady(),
      home: root,
      environment: [:],
      supportDirectory: root,
      bootTimeout: .seconds(3),
      pollInterval: .milliseconds(20)
    )
    let device = try await manager.boot(id: "android:Pixel_8")
    #expect(device.state == DeviceState.booted)
    #expect(device.serial == "emulator-5554")
    let records = try FileManager.default.contentsOfDirectory(
      at: root.appendingPathComponent("pids"),
      includingPropertiesForKeys: nil
    )
    let record = try #require(records.first)
    let saved = try JSONDecoder().decode(SavedProcess.self, from: Data(contentsOf: record))
    #expect(saved.arguments.contains("-avd"))
    #expect(saved.arguments.contains("Pixel_8"))
    #expect(saved.arguments.contains("-grpc"))
    #expect(saved.arguments.contains("8554"))
    try await manager.stop(id: "android:Pixel_8")
    try await Task.sleep(for: .milliseconds(100))
    #expect(kill(saved.pid, 0) != 0)
  }

  @Test func doesNotStartASecondCopyOfARunningAVD() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = RunningGate(running: true)
    let runner = ScriptedCommandRunner { call in
      if call.arguments.contains("devices") {
        let text =
          gate.running
          ? "List of devices attached\nemulator-5554\tdevice\n" : "List of devices attached\n"
        return CommandResult(status: 0, stdout: text)
      }
      if call.arguments.contains("ro.boot.qemu.avd_name") {
        return CommandResult(status: 0, stdout: "Pixel_8\n")
      }
      if call.arguments.contains("sys.boot_completed") {
        return CommandResult(status: 0, stdout: "1\n")
      }
      if call.arguments.contains("-list-avds") {
        return CommandResult(status: 0, stdout: "Pixel_8\n")
      }
      if call.arguments.contains("emu") {
        gate.running = false
        return CommandResult(status: 0, stdout: "OK\n")
      }
      return CommandResult(status: 0, stdout: "")
    }
    let supervisor = Supervisor(directory: root)
    let manager = DeviceManager(
      supervisor: supervisor,
      locator: MapLocator(files: [
        "emulator": URL(fileURLWithPath: "/bin/echo"),
        "adb": URL(fileURLWithPath: "/bin/echo"),
      ]),
      runner: runner,
      status: AlwaysReady(),
      home: root,
      environment: [:],
      supportDirectory: root,
      bootTimeout: .seconds(3),
      pollInterval: .milliseconds(20)
    )
    let device = try await manager.boot(id: "android:Pixel_8")
    #expect(device.serial == "emulator-5554")
    let pids =
      (try? FileManager.default.contentsOfDirectory(
        at: root.appendingPathComponent("pids"),
        includingPropertiesForKeys: nil
      )) ?? []
    #expect(pids.isEmpty)
    try await manager.stop(id: "android:Pixel_8")
    #expect(
      runner.calls().contains { $0.arguments.contains("emu") && $0.arguments.contains("kill") })
  }

  @Test func setsAndClearsTheEmulatorHTTPProxy() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = ScriptedCommandRunner { call in
      if call.arguments.contains("devices") {
        return CommandResult(status: 0, stdout: "List of devices attached\nemulator-5554\tdevice\n")
      }
      if call.arguments.contains("ro.boot.qemu.avd_name") {
        return CommandResult(status: 0, stdout: "Pixel_8\n")
      }
      if call.arguments.contains("sys.boot_completed") {
        return CommandResult(status: 0, stdout: "1\n")
      }
      if call.arguments.contains("-list-avds") {
        return CommandResult(status: 0, stdout: "Pixel_8\n")
      }
      if call.arguments.contains("http_proxy") {
        return CommandResult(status: 0, stdout: "")
      }
      return CommandResult(status: 0, stdout: "")
    }
    let manager = DeviceManager(
      supervisor: Supervisor(directory: root),
      locator: MapLocator(files: [
        "emulator": URL(fileURLWithPath: "/bin/echo"),
        "adb": URL(fileURLWithPath: "/bin/echo"),
      ]),
      runner: runner,
      status: AlwaysReady(),
      home: root,
      environment: [:],
      supportDirectory: root
    )
    _ = try await manager.boot(id: "android:Pixel_8")
    try await manager.setHTTPProxy(id: "android:Pixel_8", address: "10.0.2.2:18080")
    try await manager.clearHTTPProxy(id: "android:Pixel_8")
    let calls = runner.calls()
    #expect(
      calls.contains {
        $0.arguments.contains("http_proxy") && $0.arguments.contains("10.0.2.2:18080")
      })
    #expect(calls.contains { $0.arguments.contains("http_proxy") && $0.arguments.contains(":0") })
  }

  @Test func rotatesTheDisplayWithWmUserRotation() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = ScriptedCommandRunner { call in
      if call.arguments.contains("user-rotation"), call.arguments.contains("lock") {
        return CommandResult(status: 0, stdout: "")
      }
      if call.arguments.contains("user-rotation") {
        return CommandResult(status: 0, stdout: "1\n")
      }
      if call.arguments.contains("devices") {
        return CommandResult(status: 0, stdout: "List of devices attached\nemulator-5554\tdevice\n")
      }
      if call.arguments.contains("ro.boot.qemu.avd_name") {
        return CommandResult(status: 0, stdout: "Pixel_8\n")
      }
      if call.arguments.contains("sys.boot_completed") {
        return CommandResult(status: 0, stdout: "1\n")
      }
      if call.arguments.contains("-list-avds") {
        return CommandResult(status: 0, stdout: "Pixel_8\n")
      }
      return CommandResult(status: 0, stdout: "")
    }
    let manager = DeviceManager(
      supervisor: Supervisor(directory: root),
      locator: MapLocator(files: [
        "emulator": URL(fileURLWithPath: "/bin/echo"),
        "adb": URL(fileURLWithPath: "/bin/echo"),
      ]),
      runner: runner,
      status: AlwaysReady(),
      home: root,
      environment: [:],
      supportDirectory: root
    )
    _ = try await manager.boot(id: "android:Pixel_8")
    try await manager.rotateDisplay(id: "android:Pixel_8")
    let calls = runner.calls()
    #expect(
      calls.contains {
        $0.arguments.contains("user-rotation") && $0.arguments.contains("lock")
          && $0.arguments.contains("2")
      })
  }

  @Test func reversesACapturePortAndSeesAnInstalledPackage() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = ScriptedCommandRunner { call in
      if call.arguments.contains("devices") {
        return CommandResult(status: 0, stdout: "List of devices attached\nemulator-5554\tdevice\n")
      }
      if call.arguments.contains("ro.boot.qemu.avd_name") {
        return CommandResult(status: 0, stdout: "Pixel_8\n")
      }
      if call.arguments.contains("sys.boot_completed") {
        return CommandResult(status: 0, stdout: "1\n")
      }
      if call.arguments.contains("-list-avds") {
        return CommandResult(status: 0, stdout: "Pixel_8\n")
      }
      if call.arguments.contains("packages") {
        return CommandResult(status: 0, stdout: "package:com.emanuelef.remote_capture\n")
      }
      if call.arguments.contains("reverse") {
        return CommandResult(status: 0, stdout: "18081\n")
      }
      return CommandResult(status: 0, stdout: "")
    }
    let manager = DeviceManager(
      supervisor: Supervisor(directory: root),
      locator: MapLocator(files: [
        "emulator": URL(fileURLWithPath: "/bin/echo"),
        "adb": URL(fileURLWithPath: "/bin/echo"),
      ]),
      runner: runner,
      status: AlwaysReady(),
      home: root,
      environment: [:],
      supportDirectory: root
    )
    _ = try await manager.boot(id: "android:Pixel_8")
    try await manager.reversePort(id: "android:Pixel_8", port: 18081)
    try await manager.installUserCertificate(
      id: "android:Pixel_8", file: root.appendingPathComponent("ca.cer"))
    #expect(
      try await manager.isPackageInstalled(
        id: "android:Pixel_8", package: "com.emanuelef.remote_capture"))
    let calls = runner.calls()
    #expect(
      calls.contains { $0.arguments.contains("reverse") && $0.arguments.contains("tcp:18081") })
    #expect(
      calls.contains {
        $0.arguments.contains("push")
          && $0.arguments.contains("/sdcard/Download/QAWorkbench-CA.cer")
      })
    #expect(
      calls.contains {
        $0.arguments.contains("android.credentials.INSTALL")
          && $0.arguments.contains("application/x-x509-ca-cert")
      })
  }

  @Test func bootsAndStopsASimulatorThroughSimctl() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let json = """
      {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-3":[
        {"udid":"AAA","name":"iPhone 17","state":"Shutdown","isAvailable":true}
      ]}}
      """
    let runner = ScriptedCommandRunner { call in
      if call.arguments.contains("list") {
        return CommandResult(status: 0, stdout: json)
      }
      return CommandResult(status: 0, stdout: "")
    }
    let manager = DeviceManager(
      supervisor: Supervisor(directory: root),
      locator: MapLocator(files: ["xcrun": URL(fileURLWithPath: "/usr/bin/xcrun")]),
      runner: runner,
      status: AlwaysReady(),
      home: root,
      environment: [:],
      supportDirectory: root
    )
    let device = try await manager.boot(id: "ios:AAA")
    #expect(device.state == DeviceState.booted)
    try await manager.stop(id: "ios:AAA")
    let calls = runner.calls().map(\.arguments)
    #expect(calls.contains(["simctl", "boot", "AAA"]))
    #expect(calls.contains(["simctl", "bootstatus", "AAA", "-b"]))
    #expect(calls.contains(["simctl", "shutdown", "AAA"]))
  }
}

struct PackageFileTests {
  @Test func recognizesZipMagicAndInstallArguments() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let apk = root.appendingPathComponent("app.apk")
    let other = root.appendingPathComponent("notes.txt")
    try Data([0x50, 0x4B, 0x03, 0x04, 0x00]).write(to: apk)
    try Data("hello".utf8).write(to: other)
    #expect(PackageFile.isAPK(apk))
    #expect(!PackageFile.isAPK(other))
    #expect(
      PackageFile.installArguments(serial: "emulator-5554", apk: apk) == [
        "-s", "emulator-5554", "install", "-r", "-t", "-d", apk.path,
      ]
    )
    #expect(
      PackageFile.replacesInstalledPackage(
        "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: Existing package com.example signatures do not match]"
      ))
    #expect(
      !PackageFile.replacesInstalledPackage(
        "Failure [INSTALL_FAILED_VERSION_DOWNGRADE: Downgrade detected]"))
  }

  @Test func findsAPKsInAFolder() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let nested = root.appendingPathComponent("build/app/outputs/flutter-apk", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let apk = nested.appendingPathComponent("app-debug.apk")
    let other = root.appendingPathComponent("notes.txt")
    let skip = root.appendingPathComponent("node_modules", isDirectory: true)
    try FileManager.default.createDirectory(at: skip, withIntermediateDirectories: true)
    let skipped = skip.appendingPathComponent("ignore.apk")
    try Data([0x50, 0x4B, 0x03, 0x04, 0x00]).write(to: apk)
    try Data([0x50, 0x4B, 0x03, 0x04, 0x00]).write(to: skipped)
    try Data("hello".utf8).write(to: other)
    #expect(PackageFile.apks(in: root).map(\.lastPathComponent) == ["app-debug.apk"])
    #expect(PackageFile.apks(in: apk) == [apk])
    #expect(PackageFile.apks(in: other).isEmpty)
    #expect(PackageFile.resolveAPKs(from: root).map(\.lastPathComponent) == ["app-debug.apk"])
    #expect(PackageFile.resolveAPKs(from: [apk]) == [apk])
  }

  @Test func listsTopLevelDownloadsAPKs() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let apk = root.appendingPathComponent("Lookmeal-qa-2.2.2(5).apk")
    let nested = root.appendingPathComponent("other", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data([0x50, 0x4B, 0x03, 0x04, 0x00]).write(to: apk)
    try Data([0x50, 0x4B, 0x03, 0x04, 0x00]).write(
      to: nested.appendingPathComponent("hidden.apk"))
    #expect(PackageFile.topLevelAPKs(in: root).map(\.lastPathComponent) == [apk.lastPathComponent])
    #expect(
      try PackageFile.listTopLevelAPKs(in: root).map(\.lastPathComponent) == [apk.lastPathComponent]
    )
    #expect(PackageFile.resolveAPKs(from: root).map(\.lastPathComponent) == [apk.lastPathComponent])
    #expect(PackageFile.resolveAPKs(from: apk).map(\.lastPathComponent) == [apk.lastPathComponent])
  }

  @Test func acceptsOnlyHttpDownloads() {
    #expect(PackageFile.acceptedDownloadURL("https://example.com/app.apk")?.host == "example.com")
    #expect(PackageFile.acceptedDownloadURL("http://127.0.0.1:8000/app.apk") != nil)
    #expect(PackageFile.acceptedDownloadURL("file:///tmp/app.apk") == nil)
    #expect(PackageFile.acceptedDownloadURL("not a url") == nil)
    #expect(PackageFile.maximumDownloadBytes == 200 * 1024 * 1024)
    #expect(
      PackageFile.acceptedDownloadURL("\"https://example.com/app.apk\"")?.host == "example.com")
    #expect(
      PackageFile.downloadArguments(
        url: URL(string: "https://example.com/app.apk")!,
        destination: URL(fileURLWithPath: "/tmp/app.apk")
      ).starts(with: ["-L", "--fail"])
    )
  }

  @Test func readsPackageNameAndLaunchArguments() {
    let badging = """
      package: name='com.qaworkbench.spike_fixture' versionCode='1'
      launchable-activity: name='com.qaworkbench.spike_fixture.MainActivity'  label='' icon=''
      """
    #expect(PackageIdentity.name(fromBadging: badging) == "com.qaworkbench.spike_fixture")
    #expect(
      PackageIdentity.activity(fromBadging: badging) == "com.qaworkbench.spike_fixture.MainActivity"
    )
    #expect(PackageIdentity.name(fromBadging: "com.foo.bar\n") == "com.foo.bar")
    #expect(
      PackageIdentity.startArguments(
        serial: "emulator-5554", package: "com.foo", activity: "com.foo.MainActivity")
        == [
          "-s", "emulator-5554", "shell", "am", "start", "-n", "com.foo/com.foo.MainActivity",
        ]
    )
    #expect(
      PackageIdentity.launchArguments(serial: "emulator-5554", package: "com.foo")
        == [
          "-s", "emulator-5554", "shell", "monkey", "-p", "com.foo", "-c",
          "android.intent.category.LAUNCHER", "1",
        ]
    )
    #expect(
      PackageIdentity.startedSuccessfully(
        "Starting: Intent { cmp=com.foo/.MainActivity }\n"))
    #expect(!PackageIdentity.startedSuccessfully("Error type 3\n"))
  }

  @Test func listsAPKsFromEmulatorStorage() {
    let listing = """
      app-debug.apk
      notes.txt
      ls: /sdcard/Download: No such file or directory
      """
    #expect(
      DeviceStorage.paths(fromListing: listing, folder: "/sdcard/Download") == [
        "/sdcard/Download/app-debug.apk"
      ]
    )
    #expect(DeviceStorage.isAPKPath("/data/local/tmp/app.apk"))
    #expect(!DeviceStorage.isAPKPath("/data/app/evil.apk"))
    #expect(!DeviceStorage.isAPKPath("/sdcard/Download/../tmp/app.apk"))
    #expect(
      PackageFile.pullArguments(
        serial: "emulator-5554",
        remote: "/data/local/tmp/app.apk",
        destination: URL(fileURLWithPath: "/tmp/app.apk")
      ) == ["-s", "emulator-5554", "pull", "/data/local/tmp/app.apk", "/tmp/app.apk"]
    )
  }

  @Test func downloadsAnAPKWhenAsked() async throws {
    guard let text = ProcessInfo.processInfo.environment["WB_APK_URL"] else { return }
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wb-download-\(UUID().uuidString).apk")
    defer { try? FileManager.default.removeItem(at: destination) }
    let url = try #require(PackageFile.acceptedDownloadURL(text))
    try await PackageFile.download(from: url, to: destination)
    #expect(PackageFile.isAPK(destination))
  }
}

private struct MapLocator: ToolLocating {
  var files: [String: URL]
  func find(named name: String, path: String, extraDirectories: [URL]) -> ToolHit? {
    files[name].map { ToolHit(url: $0, onPath: true) }
  }
}

private struct AlwaysReady: GuestReadyChecking {
  func isBooted(grpcPort: Int) async -> Bool { true }
}

private final class RunningGate: @unchecked Sendable {
  var running: Bool
  init(running: Bool) { self.running = running }
}

private struct SavedProcess: Decodable {
  var pid: Int32
  var arguments: [String]
}

private func makeRoot() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
