import Foundation
import WBCore
import WBProcess

public actor DeviceManager {
  private let supervisor: Supervisor
  private let locator: any ToolLocating
  private let runner: any CommandExecuting
  private let status: any GuestReadyChecking
  private let home: URL
  private let environment: [String: String]
  private let supportDirectory: URL
  private var owned: [String: OwnedEmulator] = [:]
  public var bootTimeout: Duration
  public var pollInterval: Duration

  public init(
    supervisor: Supervisor,
    locator: any ToolLocating,
    runner: any CommandExecuting,
    status: any GuestReadyChecking,
    home: URL,
    environment: [String: String],
    supportDirectory: URL,
    bootTimeout: Duration = .seconds(180),
    pollInterval: Duration = .seconds(1)
  ) {
    self.supervisor = supervisor
    self.locator = locator
    self.runner = runner
    self.status = status
    self.home = home
    self.environment = environment
    self.supportDirectory = supportDirectory
    self.bootTimeout = bootTimeout
    self.pollInterval = pollInterval
  }

  public func inventory() async -> DeviceInventory {
    var devices: [Device] = []
    var problems: [WBError] = []
    do {
      devices.append(contentsOf: try await androidDevices())
    } catch let error as WBError {
      problems.append(error)
    } catch {
      problems.append(
        WBError.wrap(error, domain: .device, code: "android.list", message: "Could not list AVDs."))
    }
    do {
      devices.append(contentsOf: try await iosDevices())
    } catch let error as WBError {
      problems.append(error)
    } catch {
      problems.append(
        WBError.wrap(
          error, domain: .device, code: "ios.list", message: "Could not list simulators.")
      )
    }
    return DeviceInventory(devices: devices, problems: problems)
  }

  public func boot(id: String) async throws -> Device {
    let parsed = try Self.parseID(id)
    switch parsed.platform {
    case .android:
      return try await bootAndroid(name: parsed.name)
    case .ios:
      return try await bootIOS(udid: parsed.name)
    }
  }

  public func stop(id: String) async throws {
    let parsed = try Self.parseID(id)
    switch parsed.platform {
    case .android:
      try await stopAndroid(name: parsed.name)
    case .ios:
      try await stopIOS(udid: parsed.name)
    }
  }

  public func stopAllOwned() async {
    for id in owned.keys {
      try? await stop(id: id)
    }
    for udid in loadSimulators() {
      try? await stopIOS(udid: udid)
    }
  }

  public func reapOwnedSimulators() async {
    for udid in loadSimulators() {
      try? await stopIOS(udid: udid)
    }
  }

  public func installAPK(id: String, file: URL) async throws {
    guard PackageFile.isAPK(file) else {
      throw WBError(
        domain: .user,
        code: "apk.format",
        message: "That file is not an APK.",
        suggestion: "Choose a .apk file, or a download that is a zip archive."
      )
    }
    let session = try await runningAndroid(id: id)
    let adb = try tool("adb")
    let arguments = PackageFile.installArguments(serial: session.serial, apk: file)
    let result = try await run(adb, arguments, timeout: .seconds(180))
    var output = (result.stdoutText + result.stderrText).trimmingCharacters(
      in: .whitespacesAndNewlines)
    if !(result.status == 0 && output.contains("Success")),
      PackageFile.replacesInstalledPackage(output),
      let identity = await packageIdentity(apk: file)
    {
      try await uninstallPackage(id: id, package: identity.name)
      let retried = try await run(adb, arguments, timeout: .seconds(180))
      output = (retried.stdoutText + retried.stderrText).trimmingCharacters(
        in: .whitespacesAndNewlines)
      guard retried.status == 0, output.contains("Success") else {
        throw installFailure(output)
      }
      try await launchInstalled(session: session, apk: file)
      return
    }
    guard result.status == 0, output.contains("Success") else {
      throw installFailure(output)
    }
    try await launchInstalled(session: session, apk: file)
  }

  private func installFailure(_ output: String) -> WBError {
    let detail = output.isEmpty ? "adb install failed." : output
    return WBError(
      domain: .device,
      code: "apk.install",
      message: "The emulator did not install that APK. \(detail)",
      suggestion: detail,
      retryable: true
    )
  }

  public func setHTTPProxy(id: String, address: String) async throws {
    let session = try await runningAndroid(id: id)
    let adb = try tool("adb")
    let result = try await run(
      adb,
      ["-s", session.serial, "shell", "settings", "put", "global", "http_proxy", address],
      timeout: .seconds(15)
    )
    guard result.status == 0 else {
      throw WBError(
        domain: .device,
        code: "proxy.set",
        message: "Could not set the emulator HTTP proxy.",
        suggestion: result.stderrText + result.stdoutText,
        retryable: true
      )
    }
  }

  public func clearHTTPProxy(id: String) async throws {
    try await setHTTPProxy(id: id, address: ":0")
  }

  public func packageAPKPaths(id: String, package: String) async throws -> [String] {
    let result = try await runADB(
      id: id, arguments: ["shell", "pm", "path", package], timeout: .seconds(15))
    return ADBText.packageAPKPaths(in: result.stdoutText + result.stderrText)
  }

  public func uninstallPackage(id: String, package: String) async throws {
    let session = try await runningAndroid(id: id)
    let adb = try tool("adb")
    let result = try await run(
      adb, ["-s", session.serial, "uninstall", package], timeout: .seconds(60))
    let text = result.stdoutText + result.stderrText
    guard result.status == 0, text.lowercased().contains("success") else {
      throw WBError(
        domain: .device,
        code: "apk.uninstall",
        message: "The emulator did not remove \(package).",
        suggestion: text,
        retryable: true
      )
    }
  }

  public func isPackageInstalled(id: String, package: String) async throws -> Bool {
    let session = try await runningAndroid(id: id)
    let adb = try tool("adb")
    let result = try await run(
      adb,
      ["-s", session.serial, "shell", "pm", "list", "packages", package],
      timeout: .seconds(10)
    )
    return (result.stdoutText + result.stderrText).contains("package:\(package)")
  }

  public func installHelperAPK(id: String, file: URL) async throws {
    guard PackageFile.isAPK(file) else {
      throw WBError(
        domain: .user,
        code: "apk.format",
        message: "That file is not an APK.",
        suggestion: "Choose a .apk file, or a download that is a zip archive."
      )
    }
    let session = try await runningAndroid(id: id)
    let adb = try tool("adb")
    let result = try await run(
      adb,
      PackageFile.installArguments(serial: session.serial, apk: file),
      timeout: .seconds(180)
    )
    let output = (result.stdoutText + result.stderrText).trimmingCharacters(
      in: .whitespacesAndNewlines)
    guard result.status == 0, output.contains("Success") else {
      throw WBError(
        domain: .device,
        code: "apk.install",
        message: "The emulator did not install that APK.",
        suggestion: output.isEmpty ? "adb install failed." : output,
        retryable: true
      )
    }
  }

  public func reversePort(id: String, port: Int) async throws {
    let session = try await runningAndroid(id: id)
    let adb = try tool("adb")
    let result = try await run(
      adb,
      ["-s", session.serial, "reverse", "tcp:\(port)", "tcp:\(port)"],
      timeout: .seconds(10)
    )
    guard result.status == 0 else {
      throw WBError(
        domain: .device,
        code: "adb.reverse",
        message: "Could not forward the emulator capture port to this Mac.",
        suggestion: result.stderrText + result.stdoutText,
        retryable: true
      )
    }
  }

  public func foregroundPackage(id: String) async throws -> String? {
    let result = try await runADB(
      id: id, arguments: ["shell", "dumpsys", "window", "windows"], timeout: .seconds(15))
    return ADBText.foregroundPackage(in: result.stdoutText + result.stderrText)
  }

  public func installUserCertificate(id: String, file: URL) async throws {
    let session = try await runningAndroid(id: id)
    let adb = try tool("adb")
    let remote = "/sdcard/Download/QAWorkbench-CA.cer"
    let pushed = try await run(
      adb,
      ["-s", session.serial, "push", file.path, remote],
      timeout: .seconds(20)
    )
    guard pushed.status == 0 else {
      throw WBError(
        domain: .device,
        code: "cert.push",
        message: "Could not copy the proxy certificate onto the emulator.",
        suggestion: pushed.stderrText + pushed.stdoutText,
        retryable: true
      )
    }
    let started = try await run(
      adb,
      [
        "-s", session.serial, "shell", "am", "start",
        "-a", "android.credentials.INSTALL",
        "-t", "application/x-x509-ca-cert",
        "-d", "file://\(remote)",
      ],
      timeout: .seconds(15)
    )
    guard started.status == 0 else {
      throw WBError(
        domain: .device,
        code: "cert.install",
        message: "Could not open the certificate installer on the emulator.",
        suggestion: started.stderrText + started.stdoutText,
        retryable: true
      )
    }
  }

  public func clearReversePort(id: String, port: Int) async throws {
    let session = try await runningAndroid(id: id)
    let adb = try tool("adb")
    _ = try await run(
      adb,
      ["-s", session.serial, "reverse", "--remove", "tcp:\(port)"],
      timeout: .seconds(10)
    )
  }

  public func runADB(id: String, arguments: [String], timeout: Duration = .seconds(20)) async throws
    -> CommandResult
  {
    let session = try await runningAndroid(id: id)
    let adb = try tool("adb")
    var args = ["-s", session.serial]
    args.append(contentsOf: arguments)
    return try await run(adb, args, timeout: timeout)
  }

  public func rotateDisplay(id: String) async throws {
    let session = try await runningAndroid(id: id)
    let adb = try tool("adb")
    let current = try await run(
      adb,
      ["-s", session.serial, "shell", "wm", "user-rotation"],
      timeout: .seconds(10)
    )
    let reported =
      (current.stdoutText + current.stderrText)
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .compactMap(Int.init)
      .first ?? 0
    let next = (reported % 4 + 1) % 4
    let result = try await run(
      adb,
      ["-s", session.serial, "shell", "wm", "user-rotation", "lock", String(next)],
      timeout: .seconds(10)
    )
    guard result.status == 0 else {
      throw WBError(
        domain: .device,
        code: "display.rotate",
        message: "Could not rotate the emulator display.",
        suggestion: result.stderrText + result.stdoutText,
        retryable: true
      )
    }
  }

  public func downloadAndInstallAPK(id: String, urlText: String) async throws {
    guard let url = PackageFile.acceptedDownloadURL(urlText) else {
      throw WBError(
        domain: .user,
        code: "apk.url",
        message: "Enter an http or https address for the APK.",
        suggestion: "The address must start with http:// or https:// and point at the .apk file."
      )
    }
    let folder = supportDirectory.appendingPathComponent("downloads", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let destination = folder.appendingPathComponent("\(UUID().uuidString).apk")
    let curl = try tool("curl")
    let downloaded = try await run(
      curl,
      PackageFile.downloadArguments(url: url, destination: destination),
      timeout: .seconds(180)
    )
    if downloaded.status != 0 {
      try? FileManager.default.removeItem(at: destination)
      throw WBError(
        domain: .resource,
        code: "apk.download",
        message: "The APK download failed.",
        suggestion: (downloaded.stderrText + downloaded.stdoutText).trimmingCharacters(
          in: .whitespacesAndNewlines),
        retryable: true
      )
    }
    guard PackageFile.isAPK(destination) else {
      try? FileManager.default.removeItem(at: destination)
      throw WBError(
        domain: .user,
        code: "apk.format",
        message: "That download is not an APK.",
        suggestion: "The address needs to point at the .apk file itself, not a web page."
      )
    }
    try await installAPK(id: id, file: destination)
  }

  public func listDeviceAPKs(id: String) async throws -> [DevicePackage] {
    let session = try await runningAndroid(id: id)
    let adb = try tool("adb")
    var packages: [DevicePackage] = []
    var seen = Set<String>()
    for folder in DeviceStorage.folders {
      let result = try await run(
        adb, ["-s", session.serial, "shell", "ls", "-1", folder], timeout: .seconds(15))
      for path in DeviceStorage.paths(
        fromListing: result.stdoutText + result.stderrText, folder: folder)
      where seen.insert(path).inserted {
        packages.append(DevicePackage(path: path))
      }
    }
    return packages.sorted { $0.path < $1.path }
  }

  public func installDeviceAPK(id: String, path: String) async throws {
    guard DeviceStorage.isAPKPath(path) else {
      throw WBError(
        domain: .user,
        code: "apk.device-path",
        message: "That path is not an APK on the emulator.",
        suggestion: "Pick a file from the emulator list."
      )
    }
    let session = try await runningAndroid(id: id)
    let adb = try tool("adb")
    let destination = supportDirectory.appendingPathComponent("downloads", isDirectory: true)
      .appendingPathComponent("\(UUID().uuidString).apk")
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let pulled = try await run(
      adb,
      PackageFile.pullArguments(serial: session.serial, remote: path, destination: destination),
      timeout: .seconds(180)
    )
    guard pulled.status == 0 else {
      try? FileManager.default.removeItem(at: destination)
      throw WBError(
        domain: .device,
        code: "apk.pull",
        message: "Could not copy that APK off the emulator.",
        suggestion: pulled.stderrText + pulled.stdoutText,
        retryable: true
      )
    }
    do {
      try await installAPK(id: id, file: destination)
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
  }

  private func runningAndroid(id: String) async throws -> AndroidSession {
    let parsed = try Self.parseID(id)
    guard parsed.platform == .android else {
      throw WBError(
        domain: .user,
        code: "apk.platform",
        message: "An APK can be installed on an Android emulator.",
        suggestion: "Boot an Android device, then choose the APK again."
      )
    }
    let sessions = try await androidSessions()
    guard let session = sessions.first(where: { $0.avd == parsed.name }) else {
      throw WBError(
        domain: .device,
        code: "apk.offline",
        message: "\(parsed.name) is not running.",
        suggestion: "Boot it, then install the APK."
      )
    }
    return session
  }

  private func launchInstalled(session: AndroidSession, apk: URL) async throws {
    guard let identity = await packageIdentity(apk: apk) else {
      throw WBError(
        domain: .device,
        code: "apk.launch-name",
        message: "The APK was installed, but its package name could not be read.",
        suggestion: "Open it from the launcher on the device."
      )
    }
    let adb = try tool("adb")
    var lastOutput = ""
    if let activity = identity.activity {
      let started = try await run(
        adb,
        PackageIdentity.startArguments(
          serial: session.serial, package: identity.name, activity: activity),
        timeout: .seconds(30)
      )
      lastOutput = started.stdoutText + started.stderrText
      if started.status == 0, PackageIdentity.startedSuccessfully(lastOutput) {
        return
      }
    }
    let launched = try await run(
      adb,
      PackageIdentity.launchArguments(serial: session.serial, package: identity.name),
      timeout: .seconds(30)
    )
    lastOutput = launched.stdoutText + launched.stderrText
    guard launched.status == 0, PackageIdentity.startedSuccessfully(lastOutput),
      !lastOutput.contains("No activities found")
    else {
      throw WBError(
        domain: .device,
        code: "apk.launch",
        message: "The APK was installed, but it did not open.",
        suggestion: lastOutput,
        retryable: true
      )
    }
  }

  private func packageIdentity(apk: URL) async -> (name: String, activity: String?)? {
    if let executable = try? tool("aapt"),
      let result = try? await run(
        executable, PackageIdentity.badgingArguments(apk: apk), timeout: .seconds(20))
    {
      let text = result.stdoutText + result.stderrText
      if let name = PackageIdentity.name(fromBadging: text) {
        return (name, PackageIdentity.activity(fromBadging: text))
      }
    }
    if let executable = try? tool("aapt2") {
      if let result = try? await run(
        executable, PackageIdentity.badgingArguments(apk: apk), timeout: .seconds(20))
      {
        let text = result.stdoutText + result.stderrText
        if let name = PackageIdentity.name(fromBadging: text) {
          return (name, PackageIdentity.activity(fromBadging: text))
        }
      }
      if let result = try? await run(
        executable, ["dump", "packagename", apk.path], timeout: .seconds(20)),
        let name = PackageIdentity.name(fromBadging: result.stdoutText + result.stderrText)
      {
        return (name, nil)
      }
    }
    return nil
  }

  private func androidDevices() async throws -> [Device] {
    let avds = try await listAVDs()
    let sessions = (try? await androidSessions()) ?? []
    return avds.map { name in
      if let session = sessions.first(where: { $0.avd == name }) {
        return Device(
          id: "android:\(name)",
          platform: .android,
          name: name,
          state: session.booted ? .booted : .booting,
          serial: session.serial,
          grpcPort: session.grpcPort,
          detail: session.detail
        )
      }
      return Device(
        id: "android:\(name)",
        platform: .android,
        name: name,
        state: .shutdown,
        detail: "Shut down"
      )
    }
  }

  private func iosDevices() async throws -> [Device] {
    let xcrun = try tool("xcrun")
    let result = try await run(xcrun, ["simctl", "list", "-j"], timeout: .seconds(40))
    guard result.status == 0 else {
      throw WBError(
        domain: .device,
        code: "simctl.list",
        message: "simctl could not list devices.",
        suggestion: result.stderrText,
        underlying: result.stdoutText
      )
    }
    guard let data = result.stdoutText.data(using: .utf8) else {
      throw WBError(domain: .parse, code: "simctl.list", message: "simctl returned an empty list.")
    }
    do {
      return try SimctlCatalog.devices(from: data)
    } catch {
      throw WBError.wrap(
        error, domain: .parse, code: "simctl.list", message: "Could not read the simulator list.")
    }
  }

  private func bootAndroid(name: String) async throws -> Device {
    let avds = try await listAVDs()
    guard avds.contains(name) else {
      throw WBError(
        domain: .user,
        code: "avd.missing",
        message: "No AVD named \(name).",
        suggestion: "Create it in Android Studio, or pick a device from the list."
      )
    }
    if let existing = try await androidSessions().first(where: { $0.avd == name }) {
      try await waitUntilReady(existing, ownedID: nil)
      return Device(
        id: "android:\(name)",
        platform: .android,
        name: name,
        state: .booted,
        serial: existing.serial,
        grpcPort: existing.grpcPort,
        detail: existing.detail
      )
    }
    let used = Set((try await androidSessions()).map(\.consolePort))
    guard let console = EmulatorLaunch.chooseConsolePort(used: used) else {
      throw WBError(
        domain: .resource,
        code: "port.busy",
        message: "Every emulator console port from 5554 to 5584 is in use.",
        suggestion: "Stop an emulator, then boot this AVD again.",
        retryable: true
      )
    }
    let grpc = EmulatorLaunch.grpcPort(forConsole: console)
    let executable = try tool("emulator")
    let id = "android:\(name)"
    let handle = try await supervisor.start(
      ProcessRequest(
        executable: executable,
        arguments: EmulatorLaunch.arguments(avd: name, consolePort: console, grpcPort: grpc),
        label: "emulator-\(name)",
        trackKind: TrackedKind.emulator,
        restart: RestartPolicy(
          maxAttempts: 2, initial: .seconds(1), multiplier: 2, maximum: .seconds(4)),
        environment: childEnvironment()
      )
    )
    let session = AndroidSession(
      avd: name,
      serial: "emulator-\(console)",
      consolePort: console,
      grpcPort: grpc,
      booted: false
    )
    owned[id] = OwnedEmulator(handle: handle, serial: session.serial, grpcPort: grpc)
    do {
      try await waitUntilReady(session, ownedID: id)
    } catch {
      await supervisor.cancelRestart(handle)
      await supervisor.stop(handle)
      owned[id] = nil
      throw error
    }
    return Device(
      id: id,
      platform: .android,
      name: name,
      state: .booted,
      serial: session.serial,
      grpcPort: grpc,
      detail: "emulator-\(console), gRPC \(grpc)"
    )
  }

  private func stopAndroid(name: String) async throws {
    let id = "android:\(name)"
    if let record = owned[id] {
      await supervisor.cancelRestart(record.handle)
    }
    let known = try? await androidSessions()
    let serial = owned[id]?.serial ?? known?.first { $0.avd == name }?.serial
    if let serial {
      if let adb = try? tool("adb") {
        _ = try? await run(adb, ["-s", serial, "emu", "kill"], timeout: .seconds(15))
      }
    }
    if let record = owned[id] {
      await supervisor.stop(record.handle)
      owned[id] = nil
      return
    }
    let deadline = ContinuousClock().now.advanced(by: .seconds(12))
    while ContinuousClock().now < deadline {
      let running = await androidStillRunning(name)
      if !running {
        return
      }
      try await Task.sleep(for: .milliseconds(250))
    }
    throw WBError(
      domain: .device,
      code: "android.stop",
      message: "\(name) is still running.",
      suggestion: "Quit the emulator from its window, then try Stop again.",
      retryable: true
    )
  }

  private func androidStillRunning(_ name: String) async -> Bool {
    guard let adb = try? tool("adb") else { return false }
    guard let listed = try? await run(adb, ["devices"], timeout: .seconds(3)), listed.status == 0
    else {
      return false
    }
    for serial in ADBText.emulatorSerials(in: listed.stdoutText) {
      guard
        let nameResult = try? await run(
          adb,
          ["-s", serial, "shell", "getprop", "ro.boot.qemu.avd_name"],
          timeout: .seconds(3)
        )
      else {
        continue
      }
      if nameResult.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == name {
        return true
      }
    }
    return false
  }

  private func bootIOS(udid: String) async throws -> Device {
    let known = try await iosDevices()
    guard let device = known.first(where: { $0.serial == udid }) else {
      throw WBError(
        domain: .user,
        code: "simulator.missing",
        message: "No simulator with that id.",
        suggestion: "Pick a simulator from the list."
      )
    }
    let xcrun = try tool("xcrun")
    if device.state != .booted {
      let boot = try await run(xcrun, ["simctl", "boot", udid], timeout: .seconds(60))
      if boot.status != 0 {
        let text = boot.stderrText + boot.stdoutText
        if !text.contains("current state: Booted") {
          throw WBError(
            domain: .device,
            code: "simulator.boot",
            message: "The simulator did not boot.",
            suggestion: text,
            retryable: true
          )
        }
      }
    }
    let ready = try await run(
      xcrun,
      ["simctl", "bootstatus", udid, "-b"],
      timeout: bootTimeout
    )
    guard ready.status == 0 else {
      throw WBError(
        domain: .device,
        code: "simulator.bootstatus",
        message: "The simulator did not finish booting.",
        suggestion: ready.stderrText,
        retryable: true
      )
    }
    rememberSimulator(udid)
    return Device(
      id: "ios:\(udid)",
      platform: .ios,
      name: device.name,
      state: .booted,
      serial: udid,
      detail: device.detail
    )
  }

  private func stopIOS(udid: String) async throws {
    let xcrun = try tool("xcrun")
    let result = try await run(xcrun, ["simctl", "shutdown", udid], timeout: .seconds(40))
    forgetSimulator(udid)
    if result.status != 0 {
      let text = result.stderrText + result.stdoutText
      if text.contains("Shutdown") {
        return
      }
      throw WBError(
        domain: .device,
        code: "simulator.stop",
        message: "The simulator did not shut down.",
        suggestion: text,
        retryable: true
      )
    }
  }

  private func waitUntilReady(_ session: AndroidSession, ownedID: String?) async throws {
    let deadline = ContinuousClock().now.advanced(by: bootTimeout)
    while ContinuousClock().now < deadline {
      if let ownedID, let record = owned[ownedID] {
        if await supervisor.pid(for: record.handle) == nil {
          let logURL = await supervisor.logURL(for: record.handle)
          let tail = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
          let excerpt = String(tail.suffix(800))
          throw WBError(
            domain: .device,
            code: "emulator.exited",
            message: "The emulator exited before \(session.avd) finished booting.",
            suggestion: "Read the log in ~/Library/Application Support/QA Workbench/logs.",
            underlying: excerpt
          )
        }
      }
      if await bootCompleted(session.serial), let port = session.grpcPort,
        await status.isBooted(grpcPort: port)
      {
        return
      }
      try await Task.sleep(for: pollInterval)
    }
    throw WBError(
      domain: .device,
      code: "android.boot",
      message: "\(session.avd) did not finish booting.",
      suggestion: "Stop it and boot it again. A cold boot can take a few minutes.",
      retryable: true
    )
  }

  private func bootCompleted(_ serial: String) async -> Bool {
    guard let adb = try? tool("adb") else { return false }
    guard
      let result = try? await run(
        adb,
        ["-s", serial, "shell", "getprop", "sys.boot_completed"],
        timeout: .seconds(10)
      )
    else {
      return false
    }
    return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
  }

  private func listAVDs() async throws -> [String] {
    let emulator = try tool("emulator")
    let result = try await run(emulator, ["-list-avds"], timeout: .seconds(30))
    guard result.status == 0 else {
      throw WBError(
        domain: .device,
        code: "avd.list",
        message: "Could not list AVDs.",
        suggestion: result.stderrText
      )
    }
    return result.stdoutText.split(whereSeparator: \.isNewline).map(String.init).filter {
      !$0.isEmpty
    }
  }

  private func androidSessions() async throws -> [AndroidSession] {
    let adb = try tool("adb")
    let listed = try await run(adb, ["devices"], timeout: .seconds(15))
    guard listed.status == 0 else {
      throw WBError(
        domain: .device, code: "adb.devices", message: "adb devices failed.",
        suggestion: listed.stderrText)
    }
    let discovery = EmulatorDiscovery.read(home: home)
    var sessions: [AndroidSession] = []
    for serial in ADBText.emulatorSerials(in: listed.stdoutText) {
      let nameResult = try await run(
        adb,
        ["-s", serial, "shell", "getprop", "ro.boot.qemu.avd_name"],
        timeout: .seconds(10)
      )
      let name = nameResult.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty, let console = ADBText.consolePort(serial: serial) else { continue }
      let endpoint = discovery.first { $0.serialPort == console || $0.avdID == name }
      let grpc = endpoint?.grpcPort ?? EmulatorLaunch.grpcPort(forConsole: console)
      let booted = await bootCompleted(serial)
      sessions.append(
        AndroidSession(
          avd: name,
          serial: serial,
          consolePort: console,
          grpcPort: grpc,
          booted: booted
        )
      )
    }
    return sessions
  }

  private func run(_ executable: URL, _ arguments: [String], timeout: Duration) async throws
    -> CommandResult
  {
    try await runner.execute(
      executable: executable,
      arguments: arguments,
      timeout: timeout,
      environment: childEnvironment()
    )
  }

  private func tool(_ name: String) throws -> URL {
    guard
      let hit = locator.find(
        named: name,
        path: environment["PATH"] ?? "",
        extraDirectories: KnownTools.extraDirectories(for: name, home: home)
      )
    else {
      throw WBError(
        domain: .environment,
        code: "tool.missing",
        message: "\(name) was not found.",
        suggestion: "Open the doctor and copy the fix it shows."
      )
    }
    return hit.url
  }

  private func childEnvironment() -> [String: String]? {
    guard let sdk = AndroidSDK.discover(environment: environment, home: home) else {
      return nil
    }
    var updates: [String: String] = [:]
    if environment["ANDROID_SDK_ROOT"] == nil {
      updates["ANDROID_SDK_ROOT"] = sdk.path
      updates["ANDROID_HOME"] = sdk.path
    }
    let prefix = "\(sdk.path)/platform-tools:\(sdk.path)/emulator"
    updates["PATH"] = prefix + ":" + (environment["PATH"] ?? "")
    return updates
  }

  private func rememberSimulator(_ udid: String) {
    var udids = loadSimulators()
    if !udids.contains(udid) {
      udids.append(udid)
    }
    storeSimulators(udids)
  }

  private func forgetSimulator(_ udid: String) {
    storeSimulators(loadSimulators().filter { $0 != udid })
  }

  private func loadSimulators() -> [String] {
    let url = simulatorFile()
    guard let data = try? Data(contentsOf: url),
      let record = try? JSONDecoder().decode(OwnedSimulators.self, from: data)
    else {
      return []
    }
    return record.udids
  }

  private func storeSimulators(_ udids: [String]) {
    let url = simulatorFile()
    if udids.isEmpty {
      try? FileManager.default.removeItem(at: url)
      return
    }
    let data = try? JSONEncoder().encode(OwnedSimulators(udids: udids))
    try? data?.write(to: url, options: .atomic)
  }

  private func simulatorFile() -> URL {
    supportDirectory.appendingPathComponent("booted-simulators.json")
  }

  static func parseID(_ id: String) throws -> (platform: DevicePlatform, name: String) {
    let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2, !parts[1].isEmpty, !parts[1].contains("\n"), !parts[1].contains("\0")
    else {
      throw WBError(
        domain: .user,
        code: "device.id",
        message: "Unknown device id.",
        suggestion: "Use an id from the device list."
      )
    }
    switch parts[0] {
    case "android":
      return (.android, parts[1])
    case "ios":
      return (.ios, parts[1])
    default:
      throw WBError(
        domain: .user,
        code: "device.id",
        message: "Unknown device id \(id).",
        suggestion: "Use an id from the device list."
      )
    }
  }
}

private struct OwnedEmulator: Sendable {
  var handle: UUID
  var serial: String
  var grpcPort: Int
}

private struct AndroidSession: Sendable {
  var avd: String
  var serial: String
  var consolePort: Int
  var grpcPort: Int?
  var booted: Bool

  var detail: String {
    if let grpcPort {
      return "\(serial), gRPC \(grpcPort)"
    }
    return serial
  }
}

private struct OwnedSimulators: Codable {
  var udids: [String]
}
