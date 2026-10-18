import Darwin
import Foundation
import Testing
import WBCore

@testable import WBProcess

struct SupervisorTests {
  @Test func retriesWithBackoffThenStops() async throws {
    let root = try makeRoot()
    defer { remove(root) }
    let count = root.appendingPathComponent("count")
    let script = try writeExecutable(
      root.appendingPathComponent("fail.sh"),
      """
      #!/bin/sh
      printf x >> '\(count.path)'
      exit 1
      """
    )
    let clock = TestClock()
    let supervisor = Supervisor(directory: root, clock: clock)
    let id = try await supervisor.start(
      ProcessRequest(
        executable: script,
        arguments: [],
        label: "fail",
        trackKind: TrackedKind.emulator,
        restart: RestartPolicy(
          maxAttempts: 3,
          initial: .milliseconds(100),
          multiplier: 2,
          maximum: .seconds(1)
        )
      )
    )
    let finished = await supervisor.waitUntilFinished(id)
    #expect(finished)
    let text = try String(contentsOf: count, encoding: .utf8)
    #expect(text == "xxx")
    #expect(clock.recordedSleeps() == [.milliseconds(100), .milliseconds(200)])
  }

  @Test func stopDoesNotRestart() async throws {
    let root = try makeRoot()
    defer { remove(root) }
    let count = root.appendingPathComponent("count")
    let script = try writeExecutable(
      root.appendingPathComponent("sleep.sh"),
      """
      #!/bin/sh
      printf x >> '\(count.path)'
      exec /bin/sleep 30
      """
    )
    let clock = TestClock()
    let supervisor = Supervisor(directory: root, clock: clock)
    let id = try await supervisor.start(
      ProcessRequest(
        executable: script,
        arguments: [],
        label: "sleep",
        trackKind: TrackedKind.emulator,
        restart: .never
      )
    )
    let started = ContinuousClock().now
    while !FileManager.default.fileExists(atPath: count.path) {
      if ContinuousClock().now > started.advanced(by: .seconds(2)) {
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    let pid = try #require(await supervisor.pid(for: id))
    await supervisor.stop(id)
    #expect(kill(pid, 0) != 0)
    try await Task.sleep(for: .milliseconds(200))
    let text = try String(contentsOf: count, encoding: .utf8)
    #expect(text == "x")
    #expect(clock.recordedSleeps().isEmpty)
  }
}

struct OrphanReaperTests {
  @Test func killsAnOrphanedSleep() throws {
    let root = try makeRoot()
    defer { remove(root) }
    let script = try writeExecutable(
      root.appendingPathComponent("orphan.sh"),
      """
      #!/bin/sh
      /bin/sleep 30 >/dev/null 2>&1 &
      echo $!
      """
    )
    let process = Process()
    process.executableURL = script
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    let pidText = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let pid = try #require(Int32(pidText))
    defer { Darwin.kill(pid, SIGKILL) }
    let record = PidRecord(
      pid: pid,
      kind: TrackedKind.emulator,
      executable: "/bin/sleep",
      arguments: ["30"],
      label: "sleep"
    )
    let data = try JSONEncoder().encode(record)
    try data.write(to: root.appendingPathComponent("\(pid).json"))
    let killed = OrphanReaper.reap(directory: root)
    #expect(killed == [pid])
    #expect(Darwin.kill(pid, 0) != 0)
  }

  @Test func leavesASupervisedProcessAlone() throws {
    let root = try makeRoot()
    defer { remove(root) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer { process.terminate() }
    let pid = process.processIdentifier
    let record = PidRecord(
      pid: pid,
      kind: TrackedKind.emulator,
      executable: "/bin/sleep",
      arguments: ["30"],
      label: "sleep"
    )
    let data = try JSONEncoder().encode(record)
    try data.write(to: root.appendingPathComponent("\(pid).json"))
    let killed = OrphanReaper.reap(directory: root)
    #expect(killed.isEmpty)
    #expect(Darwin.kill(pid, 0) == 0)
  }

  @Test func leavesARecycledPidAlone() throws {
    let root = try makeRoot()
    defer { remove(root) }
    let record = PidRecord(
      pid: ProcessInfo.processInfo.processIdentifier,
      kind: TrackedKind.emulator,
      executable: "/bin/sleep",
      arguments: ["30"],
      label: "not-us"
    )
    let data = try JSONEncoder().encode(record)
    try data.write(to: root.appendingPathComponent("self.json"))
    let killed = OrphanReaper.reap(directory: root)
    #expect(killed.isEmpty)
  }

  @Test func matchesTheQemuProcessTheEmulatorLauncherBecomes() {
    let record = PidRecord(
      pid: 1,
      kind: TrackedKind.emulator,
      executable: "/Users/yadhu/Library/Android/sdk/emulator/emulator",
      arguments: ["-avd", "Pixel_8", "-port", "5554"],
      label: "emulator-Pixel_8"
    )
    let command =
      "qemu-system-aarch64-headless -avd Pixel_8 -port 5554 -grpc 8554 -no-window"
    #expect(OrphanReaper.commandMatches(command, record: record))
    let unrelated = PidRecord(
      pid: 1,
      kind: TrackedKind.emulator,
      executable: "/bin/sleep",
      arguments: ["30"],
      label: "sleep"
    )
    #expect(!OrphanReaper.commandMatches("qemu-system-aarch64 -avd Pixel_8", record: unrelated))
  }
}

struct DoctorTests {
  @Test func passesToolsThatAreOnPath() async throws {
    let root = try makeRoot()
    defer { remove(root) }
    let sdk = root.appendingPathComponent("sdk")
    try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
    let doctor = Doctor(
      path: "/usr/bin",
      home: root,
      osMajor: 26,
      architecture: "arm64",
      environment: ["ANDROID_SDK_ROOT": sdk.path],
      locator: MapLocator(hits: onPathHits()),
      runner: MapRunner(outputs: versionOutputs(avds: "Pixel_8\n"))
    )
    let report = await doctor.inspect()
    #expect(!report.hasFailures)
    #expect(report.checks.first { $0.name == "adb" }?.status == .pass)
    #expect(report.checks.first { $0.name == "flutter" }?.status == .pass)
    #expect(report.checks.first { $0.name == "AVDs" }?.summary == "Pixel_8")
  }

  @Test func warnsWhenToolsAreOffPath() async throws {
    let root = try makeRoot()
    defer { remove(root) }
    let home = root.appendingPathComponent("home")
    let sdk = home.appendingPathComponent("Library/Android/sdk")
    try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
    let adb = sdk.appendingPathComponent("platform-tools/adb")
    let emulator = sdk.appendingPathComponent("emulator/emulator")
    let flutter = home.appendingPathComponent("develop/flutter/bin/flutter")
    let doctor = Doctor(
      path: "/usr/bin:/bin",
      home: home,
      osMajor: 26,
      architecture: "arm64",
      environment: [:],
      locator: MapLocator(
        hits: [
          "xcodebuild": ToolHit(url: URL(fileURLWithPath: "/usr/bin/xcodebuild"), onPath: true),
          "swift": ToolHit(url: URL(fileURLWithPath: "/usr/bin/swift"), onPath: true),
          "xcrun": ToolHit(url: URL(fileURLWithPath: "/usr/bin/xcrun"), onPath: true),
          "adb": ToolHit(url: adb, onPath: false),
          "emulator": ToolHit(url: emulator, onPath: false),
          "flutter": ToolHit(url: flutter, onPath: false),
        ]
      ),
      runner: MapRunner(outputs: versionOutputs(avds: ""))
    )
    let report = await doctor.inspect()
    #expect(report.checks.first { $0.name == "adb" }?.status == .warn)
    #expect(report.checks.first { $0.name == "emulator" }?.status == .warn)
    #expect(report.checks.first { $0.name == "flutter" }?.status == .warn)
    #expect(report.checks.first { $0.name == "adb" }?.status != .pass)
    #expect(report.checks.first { $0.name == "Android SDK" }?.status == .warn)
    let zshrc = home.appendingPathComponent(".zshrc")
    try "original\n".write(to: zshrc, atomically: true, encoding: .utf8)
    let fix = try Doctor.writeFix(report, to: home.appendingPathComponent("support"))
    let env = try String(contentsOf: #require(fix), encoding: .utf8)
    #expect(env.contains("export PATH="))
    #expect(env.contains("ANDROID_SDK_ROOT"))
    #expect(try String(contentsOf: zshrc, encoding: .utf8) == "original\n")
  }

  @Test func failsWhenToolsAreMissing() async throws {
    let home = try makeRoot()
    defer { remove(home) }
    let doctor = Doctor(
      path: "/usr/bin:/bin",
      home: home,
      osMajor: 14,
      architecture: "x86_64",
      environment: [:],
      locator: MapLocator(hits: [:]),
      runner: MapRunner(outputs: [:])
    )
    let report = await doctor.inspect()
    #expect(report.hasFailures)
    #expect(report.checks.first { $0.name == "macOS" }?.status == .fail)
    #expect(report.checks.first { $0.name == "CPU" }?.status == .warn)
    #expect(report.checks.first { $0.name == "adb" }?.status == .fail)
    #expect(report.checks.first { $0.name == "flutter" }?.status == .fail)
    #expect(report.checks.first { $0.name == "Android SDK" }?.status == .fail)
    #expect(try Doctor.writeFix(report, to: home) == nil)
  }
}

struct ToolLocatorTests {
  @Test func pathBeatsAKnownDirectory() throws {
    let root = try makeRoot()
    defer { remove(root) }
    let pathBin = root.appendingPathComponent("bin")
    let extra = root.appendingPathComponent("extra")
    try FileManager.default.createDirectory(at: pathBin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
    _ = try writeExecutable(pathBin.appendingPathComponent("adb"), "#!/bin/sh\nexit 0\n")
    _ = try writeExecutable(extra.appendingPathComponent("adb"), "#!/bin/sh\nexit 0\n")
    let hit = SystemToolLocator().find(
      named: "adb",
      path: pathBin.path,
      extraDirectories: [extra]
    )
    #expect(hit?.onPath == true)
    #expect(hit?.url.deletingLastPathComponent().path == pathBin.path)
  }

  @Test func findsMitmdumpInTheLocalVenvBeforeHomebrew() {
    let dirs = KnownTools.extraDirectories(
      for: "mitmdump", home: URL(fileURLWithPath: "/tmp", isDirectory: true))
    #expect(dirs.contains { $0.path.contains("mitmvenv/bin") })
    #expect(dirs.first?.path.contains("mitmvenv/bin") == true)
  }

  @Test func prefersLocalMitmdumpOverPath() throws {
    let root = try makeRoot()
    defer { remove(root) }
    let pathBin = root.appendingPathComponent("bin")
    let extra = root.appendingPathComponent("venv/bin")
    try FileManager.default.createDirectory(at: pathBin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
    _ = try writeExecutable(pathBin.appendingPathComponent("mitmdump"), "#!/bin/sh\nexit 0\n")
    _ = try writeExecutable(extra.appendingPathComponent("mitmdump"), "#!/bin/sh\nexit 0\n")
    let hit = SystemToolLocator().find(
      named: "mitmdump",
      path: pathBin.path,
      extraDirectories: [extra]
    )
    #expect(hit?.onPath == false)
    #expect(hit?.url.deletingLastPathComponent().path == extra.path)
  }
}

private struct MapLocator: ToolLocating {
  var hits: [String: ToolHit]
  func find(named name: String, path: String, extraDirectories: [URL]) -> ToolHit? {
    hits[name]
  }
}

private final class MapRunner: CommandExecuting, @unchecked Sendable {
  var outputs: [String: CommandResult]
  init(outputs: [String: CommandResult]) {
    self.outputs = outputs
  }

  func execute(
    executable: URL,
    arguments: [String],
    timeout: Duration,
    environment: [String: String]?
  ) async throws -> CommandResult {
    let key = ([executable.lastPathComponent] + arguments).joined(separator: " ")
    return outputs[key] ?? CommandResult(status: 1, stdout: "", stderr: "missing \(key)")
  }
}

private final class TestClock: WBClock, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [Duration] = []

  func sleep(for duration: Duration) async throws {
    try Task.checkCancellation()
    remember(duration)
  }

  func recordedSleeps() -> [Duration] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  private func remember(_ duration: Duration) {
    lock.lock()
    recorded.append(duration)
    lock.unlock()
  }
}

struct PtyTests {
  @Test func readsFromAPseudoTerminal() async throws {
    let terminal = PseudoTerminal()
    try terminal.start(
      executable: URL(fileURLWithPath: "/bin/echo"),
      arguments: ["pty-ok"],
      directory: URL(fileURLWithPath: "/"),
      environment: [:]
    )
    var text = ""
    let deadline = ContinuousClock().now.advanced(by: .seconds(2))
    for await chunk in terminal.bytes() {
      text += String(decoding: chunk, as: UTF8.self)
      if text.contains("pty-ok") || ContinuousClock().now >= deadline {
        break
      }
    }
    #expect(text.contains("pty-ok"))
    _ = await terminal.waitForExit()
  }
}

private func onPathHits() -> [String: ToolHit] {
  let names = ["xcodebuild", "swift", "xcrun", "adb", "emulator", "flutter"]
  var hits: [String: ToolHit] = [:]
  for name in names {
    hits[name] = ToolHit(url: URL(fileURLWithPath: "/usr/bin/\(name)"), onPath: true)
  }
  return hits
}

private func versionOutputs(avds: String) -> [String: CommandResult] {
  [
    "xcodebuild -version": CommandResult(status: 0, stdout: "Xcode 26.3\n"),
    "swift --version": CommandResult(status: 0, stdout: "Apple Swift version 6.2\n"),
    "flutter --version": CommandResult(status: 0, stdout: "Flutter 3.41.8\n"),
    "adb version": CommandResult(status: 0, stdout: "Android Debug Bridge version 1.0.41\n"),
    "emulator -version": CommandResult(status: 0, stdout: "Android emulator version 36.5.11.0\n"),
    "emulator -list-avds": CommandResult(status: 0, stdout: avds),
    "xcrun simctl list runtimes -j": CommandResult(
      status: 0,
      stdout: #"{"runtimes":[{"name":"iOS 26.3","isAvailable":true}]}"#
    ),
  ]
}

private func makeRoot() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func remove(_ url: URL) {
  try? FileManager.default.removeItem(at: url)
}

private func writeExecutable(_ url: URL, _ body: String) throws -> URL {
  try body.write(to: url, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  return url
}
