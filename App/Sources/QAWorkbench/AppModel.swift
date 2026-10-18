import AppKit
import SwiftUI
import WBCore
import WBDevices
import WBFlutter
import WBInspect
import WBMirror
import WBNetwork
import WBProcess
import WBSnapshot
import WBVision

@MainActor
@Observable
final class AppModel {
  static let shared = AppModel()

  var devices: [Device] = []
  var checks: [EnvironmentCheck] = []
  var selection: String?
  var statusText = "Checking this Mac…"
  var busy = false
  var needsAuthorization: Bool
  var showDoctor = false
  var problems: [String] = []
  var frame: DeviceFrame?
  var canTouch = false
  var apkLink = ""
  var tree: Node?
  var selectedNodeID: String?
  var inspectMode = false
  var dumping = false
  var treeMessage = ""
  var devicePackages: [DevicePackage] = []
  var selectedDevicePackage: String?
  var macDownloadAPKs: [URL] = []
  var selectedMacDownload: String?
  var flutterProject: URL?
  var flutterLog: [String] = []
  var flutterRunning = false
  var networkEvents: [NetworkEvent] = []
  var selectedNetworkID: String?
  var networkFilter: NetworkFilter = .all
  var networkQuery = ""
  var networkPaused = false
  var networkMessage =
    "Run or Attach a debug Flutter app for dart:io HTTP. Boot Android to capture native HTTP through the emulator proxy."
  var selectedNetworkBodies: NetworkBodies?
  var textMode = false
  var translateMode = false
  var textRuns: [TextRun] = []
  var selectedTextID: String?
  var targetLanguage = "en"
  var translationMessage = ""
  var proxyRunning = false
  var packetCaptureRunning = false
  var httpsIntercept = false
  var snapshots: [SnapshotRecord] = []
  var selectedSnapshotID: String?
  var capturingSnapshot = false
  var clipboardText = ""
  let translationBroker = TranslationBroker()

  private let supervisor: Supervisor
  private let manager: DeviceManager
  private let locator: SystemToolLocator
  private let runner: SystemCommandRunner
  private let home: URL
  private let environment: [String: String]
  private let support: URL
  private var mirrorKey = ""
  private var mirrorTask: Task<Void, Never>?
  private var touchChain: Task<Void, Never>?
  private var androidMirror: AndroidMirror?
  private var simulatorMirror: SimulatorMirror?
  private var androidNodes: UiAutomatorSource?
  private var inspectorKey = ""
  private let flutter = FlutterDriver()
  private var flutterLogTask: Task<Void, Never>?
  private let networkStore = NetworkStore()
  private let proxyEngine: ProxyEngine
  private let packetEngine: PacketEngine
  private var proxyDeviceID: String?
  private var startingProxy = false
  private var vmService: VMService?
  private var profileSource: HttpProfileSource?
  private var networkTask: Task<Void, Never>?
  private var networkPoll: Task<Void, Never>?
  private var logcatTask: Task<Void, Never>?
  private var captureWatch: Task<Void, Never>?
  private var capturePackage: String?
  private var captureSocks5 = false
  private var interceptPackage: String?
  private var preparedPackages = Set<String>()
  private var adjustingCapture = false
  private var captureStartedAt: Date?
  private var proxyInterceptEnabled = false
  private let translationCache = TranslationCache()
  private var ocrTask: Task<Void, Never>?
  private let snapshotStore: SnapshotStore

  private init() {
    let environment = ProcessInfo.processInfo.environment
    let home = FileManager.default.homeDirectoryForCurrentUser
    let support = (try? AppPaths.ensure(home: home)) ?? AppPaths.supportDirectory(home: home)
    _ = OrphanReaper.reap(directory: support.appendingPathComponent("pids"))
    supervisor = Supervisor(directory: support)
    let locator = SystemToolLocator()
    let runner = SystemCommandRunner()
    let curl =
      locator.find(
        named: "curl",
        path: environment["PATH"] ?? "",
        extraDirectories: KnownTools.extraDirectories(for: "curl", home: home)
      )?.url ?? URL(fileURLWithPath: "/usr/bin/curl")
    manager = DeviceManager(
      supervisor: supervisor,
      locator: locator,
      runner: runner,
      status: CurlEmulatorStatus(curl: curl, runner: runner),
      home: home,
      environment: environment,
      supportDirectory: support
    )
    self.locator = locator
    self.runner = runner
    self.home = home
    self.environment = environment
    self.support = support
    self.proxyEngine = ProxyEngine(store: networkStore)
    self.packetEngine = PacketEngine(store: networkStore)
    self.snapshotStore = SnapshotStore(
      directory: support.appendingPathComponent("snapshots", isDirectory: true))
    needsAuthorization = !UserDefaults.standard.bool(forKey: Self.authorizationKey)
  }

  func start() async {
    flutterLogTask = Task {
      let stream = await flutter.events()
      for await line in stream {
        if flutterLog.count > 400 {
          flutterLog.removeFirst(flutterLog.count - 400)
        }
        flutterLog.append(line)
      }
    }
    let networkStream = await networkStore.changes()
    networkTask = Task {
      for await _ in networkStream {
        await refreshNetwork()
      }
    }
    networkPoll = Task {
      while !Task.isCancelled {
        await refreshNetwork()
        try? await Task.sleep(for: .milliseconds(400))
      }
    }
    await manager.reapOwnedSimulators()
    await refreshDoctor()
    await refreshDevices()
    refreshMacDownloads()
    await loadSnapshots()
    await startProxyIfNeeded()
  }

  func acknowledge() {
    UserDefaults.standard.set(true, forKey: Self.authorizationKey)
    needsAuthorization = false
  }

  func refreshDoctor() async {
    let report = await Doctor.live().inspect()
    checks = report.checks
    if report.hasFailures {
      statusText = "This Mac is missing a tool the workbench needs."
    }
  }

  func refreshDevices() async {
    let inventory = await manager.inventory()
    devices = inventory.devices
    problems = inventory.problems.map(\.message)
    if selection == nil || !devices.contains(where: { $0.id == selection }) {
      selection =
        devices.first(where: { $0.platform == .android && $0.state == .booted })?.id
        ?? devices.first?.id
    }
    if !inventory.problems.isEmpty {
      statusText = inventory.problems[0].message
    } else if statusText == "Checking this Mac…" {
      statusText = devices.isEmpty ? "No devices yet." : "Pick a device and boot it."
    }
    attachMirror()
    attachInspector()
    await startProxyIfNeeded()
  }

  func bootSelected() async {
    guard let selection else { return }
    busy = true
    statusText = "Booting \(selection)…"
    defer { busy = false }
    do {
      let device = try await manager.boot(id: selection)
      statusText = "\(device.name) is booted."
    } catch {
      statusText = (error as? WBError)?.message ?? error.localizedDescription
    }
    await refreshDevices()
  }

  func stopSelected() async {
    guard let selection else { return }
    busy = true
    statusText = "Stopping \(selection)…"
    defer { busy = false }
    do {
      await stopProxy()
      try await manager.stop(id: selection)
      statusText = "\(selection) is shut down."
    } catch {
      statusText = (error as? WBError)?.message ?? error.localizedDescription
    }
    await refreshDevices()
  }

  func touch(x: Int, y: Int, pressure: Int) {
    if inspectMode {
      if pressure == 0 {
        selectAt(x: x, y: y)
      }
      return
    }
    if textMode || translateMode {
      if pressure == 0 {
        selectText(x: x, y: y)
      }
      return
    }
    guard canTouch, let mirror = androidMirror else { return }
    let previous = touchChain
    touchChain = Task {
      _ = await previous?.value
      if Task.isCancelled { return }
      try? await mirror.move(x: x, y: y, pressure: pressure)
      if pressure == 0 {
        await refreshTree()
      }
    }
  }

  func sendKey(_ key: String) {
    guard canTouch, let mirror = androidMirror else { return }
    let previous = touchChain
    touchChain = Task {
      _ = await previous?.value
      try? await mirror.key(key)
      await refreshTree()
    }
  }

  func rotateDevice() async {
    guard let selection, canTouch else { return }
    do {
      try await manager.rotateDisplay(id: selection)
      statusText = "Rotated the display."
      await refreshTree()
    } catch {
      statusText = (error as? WBError)?.message ?? error.localizedDescription
    }
  }

  func readClipboard() async {
    guard canTouch, let mirror = androidMirror else { return }
    do {
      clipboardText = try await mirror.clipboard()
      statusText = "Read the clipboard."
    } catch {
      statusText = (error as? WBError)?.message ?? error.localizedDescription
    }
  }

  func writeClipboard() async {
    guard canTouch, let mirror = androidMirror else { return }
    do {
      try await mirror.setClipboard(clipboardText)
      statusText = "Set the clipboard."
    } catch {
      statusText = (error as? WBError)?.message ?? error.localizedDescription
    }
  }

  func captureSnapshot() async {
    if capturingSnapshot { return }
    capturingSnapshot = true
    defer { capturingSnapshot = false }
    do {
      var picture = frame
      if let mirror = androidMirror, let full = try? await mirror.fullFrame() {
        picture = full
      }
      guard let picture, let image = FrameImage.cgImage(from: picture),
        let png = SnapshotImage.png(from: image)
      else {
        statusText = "There is no frame to capture yet."
        return
      }
      var xml = "<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>\n<hierarchy/>"
      if let source = androidNodes, let dumped = try? await source.dumpXML(), dumped.contains("<") {
        xml = dumped
      }
      let record = try await snapshotStore.save(SnapshotCapture(png: png, xml: xml))
      snapshots.insert(record, at: 0)
      selectedSnapshotID = record.id
      statusText = "Saved snapshot \(record.id)."
    } catch {
      statusText = (error as? WBError)?.message ?? error.localizedDescription
    }
  }

  private func loadSnapshots() async {
    snapshots = (try? await snapshotStore.list()) ?? []
    if selectedSnapshotID == nil {
      selectedSnapshotID = snapshots.first?.id
    }
  }

  func selectAt(x: Int, y: Int) {
    guard let tree else { return }
    if let hit = HitTest.node(atX: x, y: y, in: tree) {
      selectedNodeID = hit.id
      statusText = hit.label
    }
  }

  func selectNode(id: String) {
    selectedNodeID = id
  }

  func refreshTree() async {
    guard let source = androidNodes else { return }
    if dumping { return }
    dumping = true
    defer { dumping = false }
    do {
      let next = try await source.dump()
      tree = next
      if let selectedNodeID, next.node(id: selectedNodeID) == nil {
        self.selectedNodeID = nil
      }
      treeMessage = ""
      if textMode || translateMode {
        rebuildTextLayer(ocr: textRuns.filter { $0.origin == .ocr })
      }
    } catch {
      treeMessage = (error as? WBError)?.message ?? error.localizedDescription
    }
  }

  func refreshDeviceAPKs() async {
    guard let selection, selectedDevice?.platform == .android, selectedDevice?.state == .booted
    else {
      devicePackages = []
      selectedDevicePackage = nil
      return
    }
    do {
      devicePackages = try await manager.listDeviceAPKs(id: selection)
      if let selectedDevicePackage,
        !devicePackages.contains(where: { $0.path == selectedDevicePackage })
      {
        self.selectedDevicePackage = devicePackages.first?.path
      } else if selectedDevicePackage == nil {
        selectedDevicePackage = devicePackages.first?.path
      }
    } catch {
      statusText = (error as? WBError)?.message ?? error.localizedDescription
    }
  }

  func installDeviceAPK() async {
    guard let selection, let selectedDevicePackage else { return }
    busy = true
    statusText = "Installing \(URL(fileURLWithPath: selectedDevicePackage).lastPathComponent)…"
    defer { busy = false }
    do {
      try await manager.installDeviceAPK(id: selection, path: selectedDevicePackage)
      statusText =
        "Installed and opened \(URL(fileURLWithPath: selectedDevicePackage).lastPathComponent) from the emulator."
      Task { await self.attachAfterInstall() }
    } catch {
      statusText = (error as? WBError)?.message ?? error.localizedDescription
    }
  }

  func refreshMacDownloads() {
    guard let folder = PackageFile.downloadsDirectory() else {
      macDownloadAPKs = []
      selectedMacDownload = nil
      return
    }
    do {
      macDownloadAPKs = try PackageFile.listTopLevelAPKs(in: folder)
      if let selectedMacDownload,
        macDownloadAPKs.contains(where: { $0.path == selectedMacDownload })
      {
        return
      }
      selectedMacDownload = macDownloadAPKs.first?.path
      if macDownloadAPKs.isEmpty {
        statusText = "No .apk files in Downloads."
      }
    } catch {
      macDownloadAPKs = []
      selectedMacDownload = nil
      statusText =
        "macOS blocked the Downloads folder. Allow QA Workbench in Privacy & Security, or use Install APK… and choose the .apk file."
    }
  }

  func installMacDownload() async {
    guard let selectedMacDownload else { return }
    await installAPKItems([URL(fileURLWithPath: selectedMacDownload)])
  }

  func chooseAPKFromPanel() {
    guard let url = pickAPKURL() else { return }
    Task { await installAPKItems([url]) }
  }

  func installAPKFile(_ result: Result<URL, Error>) async {
    switch result {
    case .failure(let error):
      statusText = (error as? WBError)?.message ?? error.localizedDescription
    case .success(let url):
      await installAPKItems([url])
    }
  }

  func installAPKItems(_ urls: [URL]) async {
    guard let selection else { return }
    var scoped: [URL] = []
    for url in urls where url.startAccessingSecurityScopedResource() {
      scoped.append(url)
    }
    defer {
      for url in scoped {
        url.stopAccessingSecurityScopedResource()
      }
    }
    let apks = PackageFile.resolveAPKs(from: urls)
    if apks.isEmpty {
      statusText = pickedAPKFile(urls) ? "That file is not an APK." : "That folder has no APK."
      return
    }
    let chosen: [URL]
    if urls.count == 1, isDirectory(urls[0]), apks.count > 1 {
      guard let file = pickAPKFile(in: urls[0], count: apks.count) else { return }
      let fileScoped = file.startAccessingSecurityScopedResource()
      if fileScoped { scoped.append(file) }
      chosen = [file]
    } else {
      chosen = apks
    }
    busy = true
    statusText = "Installing \(chosen[0].lastPathComponent)…"
    defer { busy = false }
    do {
      let folder = support.appendingPathComponent("downloads", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      for apk in chosen {
        statusText = "Installing \(apk.lastPathComponent)…"
        let copy = folder.appendingPathComponent("\(UUID().uuidString).apk")
        try copyAPK(apk, to: copy)
        try await manager.installAPK(id: selection, file: copy)
      }
      if chosen.count == 1 {
        statusText =
          "Installed and opened \(chosen[0].lastPathComponent) on \(selectedDevice?.name ?? "the emulator")."
      } else {
        statusText =
          "Installed and opened \(chosen.count) APKs on \(selectedDevice?.name ?? "the emulator")."
      }
      Task { await self.attachAfterInstall() }
    } catch {
      statusText = (error as? WBError)?.message ?? error.localizedDescription
    }
  }

  private func pickAPKURL() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = PackageFile.downloadsDirectory()
    panel.prompt = "Install"
    panel.message = "Choose an APK file, or a folder that contains one."
    guard panel.runModal() == .OK else { return nil }
    return panel.url
  }

  private func pickAPKFile(in folder: URL, count: Int) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = folder
    panel.prompt = "Install"
    panel.message = "This folder has \(count) APKs. Choose the one to install."
    guard panel.runModal() == .OK else { return nil }
    return panel.url
  }

  private func copyAPK(_ apk: URL, to destination: URL) throws {
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    do {
      try FileManager.default.copyItem(at: apk, to: destination)
    } catch {
      let data = try Data(contentsOf: apk)
      try data.write(to: destination, options: .atomic)
    }
  }

  private func pickedAPKFile(_ urls: [URL]) -> Bool {
    urls.contains { url in
      var isDirectory = ObjCBool(false)
      return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        && !isDirectory.boolValue
    }
  }

  private func isDirectory(_ url: URL) -> Bool {
    var isDirectory = ObjCBool(false)
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  func chooseFlutterProjectFromPanel() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    chooseFlutterProject(.success(url))
  }

  func chooseFlutterProject(_ result: Result<URL, Error>) {
    switch result {
    case .failure(let error):
      statusText = error.localizedDescription
    case .success(let url):
      let scoped = url.startAccessingSecurityScopedResource()
      defer {
        if scoped { url.stopAccessingSecurityScopedResource() }
      }
      if MachineProtocol.isProject(url) {
        flutterProject = url
        statusText = "Flutter project: \(url.lastPathComponent)"
      } else {
        statusText = "That folder has no pubspec.yaml."
      }
    }
  }

  func runFlutter() async {
    guard let project = flutterProject, let device = flutterDevice else { return }
    guard let flutterTool = tool("flutter") else {
      statusText = "flutter was not found."
      return
    }
    busy = true
    flutterRunning = true
    statusText = "Starting Flutter…"
    defer { busy = false }
    await startProxyIfNeeded()
    do {
      let session = try await flutter.start(
        project: project,
        device: device,
        flutter: flutterTool,
        supportDirectory: support,
        environment: flutterEnvironment()
      )
      do {
        try await attachNetwork(wsUri: session.wsUri)
        statusText = "Flutter is running. \(session.appId)"
      } catch {
        statusText =
          "Flutter is running, but the HTTP profile did not connect. \((error as? WBError)?.message ?? error.localizedDescription)"
      }
    } catch {
      flutterRunning = false
      statusText = (error as? WBError)?.message ?? error.localizedDescription
    }
  }

  func reloadFlutter(full: Bool) async {
    do {
      if full {
        try await flutter.hotRestart()
        try await profileSource?.refreshIsolates()
        statusText = "Hot restart sent."
      } else {
        try await flutter.hotReload()
        statusText = "Hot reload sent."
      }
    } catch {
      statusText = (error as? WBError)?.message ?? error.localizedDescription
    }
  }

  func attachFlutter() async {
    busy = true
    defer { busy = false }
    await attachFlutter(quiet: false, timeout: .seconds(90))
  }

  func stopFlutter() async {
    await detachVM()
    await flutter.stop()
    flutterRunning = false
    networkMessage = await networkStatusMessage()
    statusText = "Flutter stopped."
  }

  func selectNetwork(id: String) {
    selectedNetworkID = id
    Task { await loadNetworkBodies() }
  }

  func applyNetworkFilter() {
    Task { await refreshNetwork() }
  }

  func toggleNetworkPause() async {
    networkPaused.toggle()
    await networkStore.setPaused(networkPaused)
  }

  func clearNetwork() async {
    await proxyEngine.skipToEnd()
    await profileSource?.clearProfile()
    await networkStore.clear()
    selectedNetworkID = nil
    selectedNetworkBodies = nil
    networkEvents = []
    try? await Task.sleep(for: .milliseconds(150))
    await networkStore.clear()
    networkEvents = []
    selectedNetworkID = nil
    selectedNetworkBodies = nil
    await refreshNetwork()
  }

  func copyNetworkURL() {
    guard let event = selectedNetworkEvent else { return }
    copyText(event.url)
  }

  func copyNetworkCurl() {
    guard let event = selectedNetworkEvent else { return }
    copyText(CurlCommand.make(event, requestBody: selectedNetworkBodies?.request))
  }

  func copyNetworkResponse() {
    guard let body = selectedNetworkBodies?.response, !body.isEmpty else { return }
    copyText(String(decoding: body, as: UTF8.self))
  }

  func exportHAR() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "network.har"
    panel.allowedContentTypes = [.json]
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      let data = await networkStore.har()
      do {
        try data.write(to: url, options: .atomic)
        statusText = "Saved HAR. Secrets in headers are masked."
      } catch {
        statusText = error.localizedDescription
      }
    }
  }

  func downloadAPK() async {
    guard let selection else { return }
    busy = true
    statusText = "Downloading the APK…"
    defer { busy = false }
    do {
      try await manager.downloadAndInstallAPK(id: selection, urlText: apkLink)
      statusText =
        "Downloaded, installed, and opened the APK on \(selectedDevice?.name ?? "the emulator")."
      Task { await self.attachAfterInstall() }
    } catch {
      statusText = (error as? WBError)?.message ?? error.localizedDescription
    }
  }

  func shutdown() async {
    mirrorTask?.cancel()
    ocrTask?.cancel()
    networkPoll?.cancel()
    networkTask?.cancel()
    logcatTask?.cancel()
    await androidMirror?.stop()
    await simulatorMirror?.stop()
    androidMirror = nil
    simulatorMirror = nil
    androidNodes = nil
    await flutter.stop()
    flutterRunning = false
    await stopProxy()
    await detachNetwork()
    await manager.stopAllOwned()
    await supervisor.stopAll()
  }

  func copyFixes() {
    let text = checks.compactMap(\.fix).joined(separator: "\n")
    guard !text.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    statusText = "Copied the fix commands."
  }

  var selectedDevice: Device? {
    devices.first { $0.id == selection }
  }

  var canInstallAPK: Bool {
    selectedDevice?.platform == .android && selectedDevice?.state == .booted && !busy
  }

  var canDumpTree: Bool {
    selectedDevice?.platform == .android && selectedDevice?.state == .booted
  }

  var canRunFlutter: Bool {
    flutterProject != nil && flutterDevice != nil && !busy && !flutterRunning
  }

  var canAttachFlutter: Bool {
    flutterDevice != nil && !busy && !flutterRunning
  }

  var flutterDevice: String? {
    guard let device = selectedDevice, device.state == .booted else { return nil }
    return device.serial
  }

  var selectedNode: Node? {
    guard let tree, let selectedNodeID else { return nil }
    return tree.node(id: selectedNodeID)
  }

  var selectedNetworkEvent: NetworkEvent? {
    networkEvents.first { $0.id == selectedNetworkID }
  }

  var selectedTextRun: TextRun? {
    textRuns.first { $0.id == selectedTextID }
  }

  var selectedSnapshot: SnapshotRecord? {
    snapshots.first { $0.id == selectedSnapshotID }
  }

  private func attachInspector() {
    let device = selectedDevice
    let key: String
    if let device, device.state == .booted {
      key = "inspect|\(device.id)|\(device.serial ?? "")"
    } else {
      key = ""
    }
    guard key != inspectorKey else { return }
    inspectorKey = key
    tree = nil
    selectedNodeID = nil
    androidNodes = nil
    devicePackages = []
    selectedDevicePackage = nil
    treeMessage = ""
    guard let device, device.state == .booted else { return }
    if device.platform == .android, let serial = device.serial, let adb = tool("adb") {
      androidNodes = UiAutomatorSource(serial: serial, adb: adb, runner: runner)
      Task {
        await refreshTree()
        await refreshDeviceAPKs()
        refreshMacDownloads()
      }
    } else if device.platform == .ios {
      treeMessage = "idb is not installed, so the simulator has no hierarchy."
    }
  }

  private func attachMirror() {
    let device = selectedDevice
    let key: String
    if let device, device.state == .booted {
      key = "\(device.id)|\(device.serial ?? "")|\(device.grpcPort ?? 0)"
    } else {
      key = ""
    }
    guard key != mirrorKey else { return }
    mirrorKey = key
    mirrorTask?.cancel()
    mirrorTask = nil
    frame = nil
    canTouch = false
    let previousAndroid = androidMirror
    let previousSimulator = simulatorMirror
    androidMirror = nil
    simulatorMirror = nil
    Task {
      await previousAndroid?.stop()
      await previousSimulator?.stop()
    }
    guard let device, device.state == .booted else {
      Task { await self.stopProxy() }
      return
    }
    if device.platform == .android {
      Task { await self.startProxyIfNeeded() }
      guard let port = device.grpcPort, let serial = device.serial else {
        statusText = "\(device.name) is booted, but its gRPC port is missing."
        return
      }
      guard let adb = tool("adb") else {
        statusText = "adb was not found, so the live picture cannot start."
        return
      }
      canTouch = true
      let mirror = AndroidMirror(grpcPort: port, serial: serial, adb: adb, runner: runner)
      androidMirror = mirror
      statusText = "Waiting for a frame from \(device.name)."
      mirrorTask = Task {
        let stream = await mirror.frames()
        for await event in stream {
          if Task.isCancelled { break }
          switch event {
          case .frame(let next):
            self.frame = next
            self.scheduleOCR()
          case .failed(let message):
            if self.frame == nil {
              self.statusText = message
            }
          }
        }
      }
    } else if device.platform == .ios, let udid = device.serial {
      guard let xcrun = tool("xcrun") else {
        statusText = "xcrun was not found, so simulator screenshots cannot start."
        return
      }
      let mirror = SimulatorMirror(udid: udid, xcrun: xcrun, runner: runner)
      simulatorMirror = mirror
      statusText = "Taking screenshots of \(device.name). Taps are not available."
      mirrorTask = Task {
        let stream = await mirror.frames()
        for await event in stream {
          if Task.isCancelled { break }
          if case .frame(let next) = event {
            self.frame = next
            self.scheduleOCR()
          }
        }
      }
      Task { await self.stopProxy() }
    }
  }

  private func attachAfterInstall() async {
    await startProxyIfNeeded()
    guard !flutterRunning, flutterDevice != nil else { return }
    await attachFlutter(quiet: true, timeout: .seconds(25))
  }

  private func attachFlutter(quiet: Bool, timeout: Duration) async {
    guard let device = flutterDevice else { return }
    guard let flutterTool = tool("flutter") else {
      if !quiet { statusText = "flutter was not found." }
      return
    }
    flutterRunning = true
    if !quiet { statusText = "Attaching Flutter…" }
    await startProxyIfNeeded()
    do {
      let session = try await flutter.attach(
        project: flutterProject,
        device: device,
        flutter: flutterTool,
        supportDirectory: support,
        environment: flutterEnvironment(),
        timeout: timeout
      )
      do {
        try await attachNetwork(wsUri: session.wsUri)
        if quiet {
          statusText += " Attached to \(session.appId)."
        } else {
          statusText = "Attached to \(session.appId)."
        }
      } catch {
        statusText =
          "Attached, but the HTTP profile did not connect. \((error as? WBError)?.message ?? error.localizedDescription)"
      }
    } catch {
      flutterRunning = false
      if quiet {
        statusText +=
          " Attach skipped: no VM service. Use a debug or profile APK, or rely on the proxy for native HTTP."
      } else {
        statusText = (error as? WBError)?.message ?? error.localizedDescription
      }
    }
  }

  private func startProxyIfNeeded() async {
    guard selectedDevice?.platform == .android, selectedDevice?.state == .booted,
      let id = selection
    else { return }
    if proxyRunning, proxyDeviceID == id { return }
    if startingProxy { return }
    startingProxy = true
    defer { startingProxy = false }
    if proxyRunning { await stopProxy() }
    guard let mitmdump = tool("mitmdump") else {
      networkMessage =
        "mitmdump is not installed. Use the pip venv under Application Support. Dart HTTP still needs Run or Attach on a debug or profile build."
      return
    }
    do {
      httpsIntercept = await prepareHTTPSIntercept(id: id)
      try await proxyEngine.start(
        mitmdump: mitmdump, supervisor: supervisor, supportDirectory: support,
        intercept: httpsIntercept)
      await waitForListen(ports: [ProxyFlow.listenPort, ProxyFlow.socksPort])
      proxyInterceptEnabled = httpsIntercept
      try await manager.setHTTPProxy(id: id, address: ProxyFlow.guestAddress)
      proxyDeviceID = id
      proxyRunning = true
      await startPacketCapture(id: id)
      startLogcatWatch(id: id)
      networkMessage = await networkStatusMessage()
    } catch {
      await packetEngine.stop()
      await proxyEngine.stop()
      proxyRunning = false
      packetCaptureRunning = false
      httpsIntercept = false
      proxyInterceptEnabled = false
      proxyDeviceID = nil
      networkMessage = (error as? WBError)?.message ?? error.localizedDescription
    }
  }

  private func stopProxy() async {
    if let id = proxyDeviceID {
      _ = try? await manager.runADB(id: id, arguments: PacketCapture.stopCommand())
      try? await manager.clearReversePort(id: id, port: PacketCapture.listenPort)
      try? await manager.clearReversePort(id: id, port: ProxyFlow.socksPort)
      try? await manager.clearHTTPProxy(id: id)
    }
    logcatTask?.cancel()
    logcatTask = nil
    captureWatch?.cancel()
    captureWatch = nil
    capturePackage = nil
    captureSocks5 = false
    await packetEngine.stop()
    await proxyEngine.stop()
    proxyRunning = false
    packetCaptureRunning = false
    httpsIntercept = false
    proxyInterceptEnabled = false
    proxyDeviceID = nil
    networkMessage = await networkStatusMessage()
  }

  private func refreshProxyIntercept(id: String) async {
    guard proxyRunning, proxyDeviceID == id, httpsIntercept != proxyInterceptEnabled,
      let mitmdump = tool("mitmdump")
    else { return }
    do {
      try await proxyEngine.start(
        mitmdump: mitmdump, supervisor: supervisor, supportDirectory: support,
        intercept: httpsIntercept)
      await waitForListen(ports: [ProxyFlow.listenPort, ProxyFlow.socksPort])
      proxyInterceptEnabled = httpsIntercept
    } catch {
      networkMessage = (error as? WBError)?.message ?? error.localizedDescription
    }
  }

  private func startPacketCapture(id: String) async {
    do {
      try await packetEngine.start()
      try await manager.reversePort(id: id, port: PacketCapture.listenPort)
      try await manager.reversePort(id: id, port: ProxyFlow.socksPort)
      if !(try await manager.isPackageInstalled(id: id, package: PacketCapture.packageName)) {
        statusText = "Installing on-device packet capture…"
        let apk = try await downloadPCAPdroid()
        try await manager.installHelperAPK(id: id, file: apk)
      }
      await retargetCapture(id: id, force: true)
      packetCaptureRunning = true
      watchCapture(id: id)
    } catch {
      packetCaptureRunning = false
      await packetEngine.stop()
      networkMessage =
        "Proxy is running. On-device capture did not start: \((error as? WBError)?.message ?? error.localizedDescription)"
    }
  }

  private func prepareHTTPSIntercept(id: String) async -> Bool {
    let foreground = try? await manager.foregroundPackage(id: id)
    let names: [String]
    if let foreground, PacketCapture.isCapturableApp(foreground) {
      names = [foreground]
    } else {
      names = ["com.proalliance.okinavi", "com.allright.lookmeal"]
    }
    for name in names {
      do {
        if try await enableReleaseIntercept(id: id, package: name) {
          interceptPackage = name
          return true
        }
      } catch {
        networkMessage = (error as? WBError)?.message ?? error.localizedDescription
      }
    }
    return false
  }

  private func watchCapture(id: String) {
    captureWatch?.cancel()
    captureWatch = Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(3))
        if Task.isCancelled { break }
        if self.httpsIntercept, !(await self.captureServiceRunning(id: id)) {
          await self.retargetCapture(id: id, force: true)
        } else {
          await self.retargetCapture(id: id, force: false)
        }
      }
    }
  }

  private func retargetCapture(id: String, force: Bool) async {
    guard !adjustingCapture else { return }
    adjustingCapture = true
    defer { adjustingCapture = false }
    let foreground = try? await manager.foregroundPackage(id: id)
    let target = PacketCapture.capturePackage(foreground: foreground, preferred: interceptPackage)
    if let target, !preparedPackages.contains(target) {
      do {
        if try await enableReleaseIntercept(id: id, package: target) {
          httpsIntercept = true
          interceptPackage = target
          await refreshProxyIntercept(id: id)
        }
      } catch {
        networkMessage = (error as? WBError)?.message ?? error.localizedDescription
      }
    }
    let running = await captureServiceRunning(id: id)
    let captureReady =
      running && capturePackage == target && captureSocks5 == httpsIntercept
    if captureReady && !force {
      _ = await approveCapturePrompts(id: id)
      return
    }
    if !force,
      let captureStartedAt,
      Date().timeIntervalSince(captureStartedAt) < 12
    {
      _ = await approveCapturePrompts(id: id)
      return
    }
    _ = try? await manager.runADB(id: id, arguments: PacketCapture.stopCommand())
    try? await Task.sleep(for: .milliseconds(300))
    _ = try? await manager.runADB(
      id: id,
      arguments: PacketCapture.startCommand(appFilter: target, socks5: httpsIntercept))
    capturePackage = target
    captureSocks5 = httpsIntercept
    captureStartedAt = Date()
    await waitForCaptureService(id: id)
  }

  private func waitForCaptureService(id: String) async {
    for _ in 0..<16 {
      if await captureServiceRunning(id: id) { return }
      _ = await approveCapturePrompts(id: id)
      try? await Task.sleep(for: .milliseconds(500))
    }
  }

  private func captureServiceRunning(id: String) async -> Bool {
    guard
      let result = try? await manager.runADB(
        id: id,
        arguments: ["shell", "dumpsys", "activity", "services", PacketCapture.packageName],
        timeout: .seconds(8)
      ),
      result.status == 0
    else {
      return false
    }
    return result.stdoutText.contains("CaptureService")
  }

  private func enableReleaseIntercept(id: String, package: String) async throws -> Bool {
    let remotes = try await manager.packageAPKPaths(id: id, package: package)
    guard !remotes.isEmpty else { return false }
    let folder = support.appendingPathComponent("intercept/\(package)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var locals: [URL] = []
    for remote in remotes {
      let local = folder.appendingPathComponent(URL(fileURLWithPath: remote).lastPathComponent)
      let pulled = try await manager.runADB(
        id: id, arguments: ["pull", remote, local.path], timeout: .seconds(120))
      guard pulled.status == 0, PackageFile.isAPK(local) else {
        throw WBError(
          domain: .device, code: "apk.pull", message: "Could not copy \(package) off the emulator.")
      }
      locals.append(local)
    }
    var work: URL?
    var so: URL?
    for local in locals {
      let dir = folder.appendingPathComponent("work-\(local.lastPathComponent)", isDirectory: true)
      try? FileManager.default.removeItem(at: dir)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      _ = try await runLocal(
        URL(fileURLWithPath: "/usr/bin/unzip"),
        ["-q", "-o", local.path, "-d", dir.path], timeout: .seconds(90))
      let library = flutterLibrary(in: dir)
      if FileManager.default.fileExists(atPath: library.path) {
        work = dir
        so = library
        break
      }
    }
    guard let work, let so else { return false }
    let original = try Data(contentsOf: so)
    if FlutterTLS.isBypassed(original) {
      preparedPackages.insert(package)
      return true
    }
    statusText = "Preparing release HTTPS capture for \(package)…"
    let patched: Data
    do {
      patched = try FlutterTLS.bypass(original)
    } catch {
      throw WBError(
        domain: .device,
        code: "flutter.tls",
        message: "Could not enable HTTPS capture on this Flutter APK."
      )
    }
    try patched.write(to: so)
    let unsigned = folder.appendingPathComponent("unsigned.apk")
    let aligned = folder.appendingPathComponent("aligned.apk")
    let signed = folder.appendingPathComponent("signed.apk")
    _ = try await runLocal(
      URL(fileURLWithPath: "/usr/bin/python3"),
      ["-c", FlutterAPK.packScript, work.path, unsigned.path], timeout: .seconds(90))
    let zipalign = try requireTool("zipalign")
    _ = try await runLocal(
      zipalign, ["-p", "-f", "4", unsigned.path, aligned.path], timeout: .seconds(60))
    try await signAPK(aligned, to: signed)
    try await manager.uninstallPackage(id: id, package: package)
    try await manager.installAPK(id: id, file: signed)
    preparedPackages.insert(package)
    return true
  }

  private func flutterLibrary(in work: URL) -> URL {
    let arm = work.appendingPathComponent("lib/arm64-v8a/\(FlutterTLS.libraryName)")
    if FileManager.default.fileExists(atPath: arm.path) { return arm }
    return work.appendingPathComponent("lib/\(FlutterTLS.libraryName)")
  }

  private func signAPK(_ input: URL, to output: URL) async throws {
    let keystore = support.appendingPathComponent("intercept/qaworkbench.jks")
    if !FileManager.default.fileExists(atPath: keystore.path) {
      try FileManager.default.createDirectory(
        at: keystore.deletingLastPathComponent(), withIntermediateDirectories: true)
      _ = try await runLocal(
        URL(fileURLWithPath: "/usr/bin/keytool"),
        [
          "-genkeypair", "-noprompt", "-alias", "qaworkbench", "-keyalg", "RSA", "-keysize", "2048",
          "-validity", "10000", "-keystore", keystore.path, "-storepass", "qaworkbench",
          "-keypass", "qaworkbench", "-dname", "CN=QA Workbench",
        ],
        timeout: .seconds(30)
      )
    }
    let apksigner = try requireTool("apksigner")
    _ = try await runLocal(
      apksigner,
      [
        "sign", "--ks", keystore.path, "--ks-pass", "pass:qaworkbench", "--key-pass",
        "pass:qaworkbench", "--ks-key-alias", "qaworkbench", "--out", output.path, input.path,
      ],
      timeout: .seconds(60)
    )
  }

  private func requireTool(_ name: String) throws -> URL {
    guard let url = tool(name) else {
      throw WBError(
        domain: .environment,
        code: "tool.\(name)",
        message: "\(name) is not installed in the Android SDK build-tools."
      )
    }
    return url
  }

  private func runLocal(_ executable: URL, _ arguments: [String], timeout: Duration) async throws
    -> CommandResult
  {
    let result = try await runner.execute(
      executable: executable, arguments: arguments, timeout: timeout, environment: nil)
    guard result.status == 0 else {
      throw WBError(
        domain: .environment,
        code: "tool.run",
        message: "\(executable.lastPathComponent) failed.",
        suggestion: result.stderrText + result.stdoutText
      )
    }
    return result
  }

  private func startLogcatWatch(id: String) {
    logcatTask?.cancel()
    logcatTask = Task { await self.pollLogcat(id: id) }
  }

  private func pollLogcat(id: String) async {
    var seen = Set<String>()
    while !Task.isCancelled {
      var names = ["com.allright.lookmeal"]
      if let foreground = try? await manager.foregroundPackage(id: id), !foreground.isEmpty {
        names.append(foreground)
      }
      var pids: [String] = []
      for name in Set(names) {
        let result = try? await manager.runADB(
          id: id, arguments: ["shell", "pidof", name], timeout: .seconds(8))
        let pid =
          (result?.stdoutText ?? "")
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        if !pid.isEmpty { pids.append(pid) }
      }
      let now = Int(Date().timeIntervalSince1970 * 1_000_000)
      for pid in Set(pids) {
        let dump = try? await manager.runADB(
          id: id, arguments: ["logcat", "-d", "-t", "80", "--pid", pid], timeout: .seconds(10))
        for line in (dump?.stdoutText ?? "").split(whereSeparator: \.isNewline) {
          guard let event = LogcatHTTP.parse(String(line), nowMicros: now) else { continue }
          if seen.insert(event.id).inserted {
            await networkStore.upsert(event)
          }
        }
      }
      try? await Task.sleep(for: .milliseconds(800))
    }
  }

  private func waitForListen(ports: [Int]) async {
    for _ in 0..<30 {
      if ports.allSatisfy(Self.isListening) { return }
      try? await Task.sleep(for: .milliseconds(100))
    }
  }

  private static func isListening(_ port: Int) -> Bool {
    let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard socket >= 0 else { return false }
    defer { Darwin.close(socket) }
    var timeout = timeval(tv_sec: 0, tv_usec: 120_000)
    _ = setsockopt(
      socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    _ = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
    return withUnsafePointer(to: &addr) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
    }
  }

  private func downloadPCAPdroid() async throws -> URL {
    let folder = support.appendingPathComponent("downloads", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let destination = folder.appendingPathComponent("PCAPdroid_\(PacketCapture.version).apk")
    if PackageFile.isAPK(destination) { return destination }
    try await PackageFile.download(from: PacketCapture.apkURL, to: destination)
    guard PackageFile.isAPK(destination) else {
      throw WBError(
        domain: .device,
        code: "pcapdroid.apk",
        message: "The PCAPdroid download was not an APK."
      )
    }
    return destination
  }

  @discardableResult
  private func approveCapturePrompts(id: String) async -> Bool {
    var tapped = false
    for _ in 0..<4 {
      let window =
        (try? await manager.runADB(
          id: id, arguments: ["shell", "dumpsys", "window"], timeout: .seconds(8)))?.stdoutText
        ?? ""
      guard PacketCapture.consentIsVisible(window) else { break }
      let sizeText =
        (try? await manager.runADB(
          id: id, arguments: ["shell", "wm", "size"], timeout: .seconds(5)))?.stdoutText ?? ""
      let size = PacketCapture.screenSize(in: sizeText) ?? (width: 1080, height: 2400)
      for point in PacketCapture.consentPoints(width: size.width, height: size.height) {
        _ = try? await manager.runADB(
          id: id,
          arguments: ["shell", "input", "tap", String(point.x), String(point.y)],
          timeout: .seconds(8)
        )
        tapped = true
        try? await Task.sleep(for: .milliseconds(400))
      }
      try? await Task.sleep(for: .milliseconds(500))
    }
    return tapped
  }

  private func attachNetwork(wsUri: String) async throws {
    await detachVM()
    let vm = VMService()
    try await vm.connect(wsUri)
    vmService = vm
    let source = HttpProfileSource(client: vm, store: networkStore)
    profileSource = source
    try await source.start()
    networkMessage = await networkStatusMessage()
  }

  private func detachVM() async {
    await profileSource?.stop()
    profileSource = nil
    await vmService?.disconnect()
    vmService = nil
  }

  private func detachNetwork() async {
    await detachVM()
    await networkStore.clear()
    networkEvents = []
    selectedNetworkID = nil
    selectedNetworkBodies = nil
    networkPaused = false
    networkMessage = await networkStatusMessage()
  }

  private func refreshNetwork() async {
    let all = await networkStore.snapshot()
    let visible = httpsIntercept ? Self.hideRedundantConnectRows(all) : all
    networkEvents = visible.filter { $0.matches(filter: networkFilter, query: networkQuery) }
    networkMessage = await networkStatusMessage()
    if let selectedNetworkID, !networkEvents.contains(where: { $0.id == selectedNetworkID }) {
      self.selectedNetworkID = networkEvents.first?.id
    } else if selectedNetworkID == nil {
      selectedNetworkID = networkEvents.first?.id
    }
    if selectedNetworkBodies == nil, selectedNetworkID != nil {
      await loadNetworkBodies()
    }
  }

  private static func hideRedundantConnectRows(_ events: [NetworkEvent]) -> [NetworkEvent] {
    let mitmHosts = Set(
      events.filter {
        $0.sources.contains(.proxy) && $0.method.uppercased() != "CONNECT" && !$0.host.isEmpty
      }.map { $0.host.lowercased() })
    guard !mitmHosts.isEmpty else { return events }
    return events.filter { event in
      if event.method.uppercased() != "CONNECT" { return true }
      return !mitmHosts.contains(event.host.lowercased())
    }
  }

  private func networkStatusMessage() async -> String {
    if proxyRunning, httpsIntercept, let id = selection {
      if !(await captureServiceRunning(id: id)) {
        return
          "Release HTTPS intercept is on, but on-device VPN capture is not running. Focus the app on the emulator; accept the VPN prompt if it appears. API rows need SOCKS capture, not CONNECT-only proxy rows."
      }
    }
    if !networkEvents.isEmpty { return "" }
    let isolates = await profileSource?.isolateCount() ?? 0
    if flutterRunning && isolates == 0 {
      return
        "Connected to the VM, waiting for dart:io HTTP profiling. Fire a request from the debug or profile app."
    }
    if flutterRunning {
      return
        "Listening on \(isolates) isolate(s) for dart:io, package:http, and dio. Native HTTP can also appear through the emulator proxy."
    }
    if proxyRunning {
      if packetCaptureRunning {
        if httpsIntercept {
          return
            "Release HTTPS intercept is on. Use the app; API rows should show method, full URL, headers, and JSON bodies (same as Lookmeal)."
        }
        return
          "Proxy and on-device capture are running. HTTPS is passed through so the app keeps internet. Lookmeal TLS and DNS (api.qa.lookmeal.com) appear when you use the app. Paths and bodies need Run or Attach on a debug or profile build."
      }
      return
        "Proxy is on the emulator at \(ProxyFlow.guestAddress). HTTPS is passed through so pages and APIs keep working. CONNECT hosts appear here. Use the phone, not a Mac browser at 127.0.0.1:18080."
    }
    if tool("mitmdump") == nil {
      return
        "Install mitmdump in the Application Support venv for installed-app HTTP, or Run/Attach a debug or profile Flutter app."
    }
    return
      "Boot an Android emulator to start the proxy, or Run/Attach a debug Flutter app for the VM profile."
  }

  private func loadNetworkBodies() async {
    guard let selectedNetworkID else {
      selectedNetworkBodies = nil
      return
    }
    if let existing = await networkStore.bodies(id: selectedNetworkID) {
      selectedNetworkBodies = existing
      return
    }
    selectedNetworkBodies = try? await profileSource?.loadBodies(id: selectedNetworkID)
  }

  func selectText(x: Int, y: Int) {
    if let hit = TextGeometry.hit(x: x, y: y, in: textRuns) {
      selectedTextID = hit.id
      statusText = hit.text
    }
  }

  func textDisplayChanged() {
    if textMode || translateMode {
      scheduleOCR()
    } else {
      ocrTask?.cancel()
      textRuns = []
      selectedTextID = nil
    }
  }

  func copySelectedText() {
    guard let run = selectedTextRun else { return }
    copyText(run.translation ?? run.text)
  }

  func scheduleOCR() {
    guard textMode || translateMode else { return }
    ocrTask?.cancel()
    ocrTask = Task { await self.captureText() }
  }

  private func captureText() async {
    try? await Task.sleep(for: .milliseconds(250))
    if Task.isCancelled { return }
    guard textMode || translateMode else { return }
    var ocr: [TextRun] = []
    do {
      if let image = await ocrImage() {
        ocr = try ScreenOCR.recognize(
          image, deviceWidth: frame?.deviceWidth ?? image.width,
          deviceHeight: frame?.deviceHeight ?? image.height)
      }
    } catch {
      translationMessage = (error as? WBError)?.message ?? error.localizedDescription
    }
    if Task.isCancelled { return }
    rebuildTextLayer(ocr: ocr)
    if translateMode {
      await translateVisible()
    }
  }

  private func ocrImage() async -> CGImage? {
    if let mirror = androidMirror, let full = try? await mirror.fullFrame() {
      return FrameImage.cgImage(from: full)
    }
    if let frame {
      return FrameImage.cgImage(from: frame)
    }
    return nil
  }

  private func rebuildTextLayer(ocr: [TextRun]) {
    let nodes = tree.map { TextLayer.runs(from: $0) } ?? []
    let merged = TextLayer.merge(nodes: nodes, ocr: ocr)
    let previous = Dictionary(uniqueKeysWithValues: textRuns.map { ($0.id, $0.translation) })
    textRuns = merged.map { run in
      var next = run
      next.translation = previous[run.id] ?? previous.first { $0.key.hasSuffix(run.text) }?.value
      return next
    }
    if let selectedTextID, !textRuns.contains(where: { $0.id == selectedTextID }) {
      self.selectedTextID = textRuns.first?.id
    }
  }

  private func translateVisible() async {
    let to = targetLanguage
    let from = to == "en" ? "ja" : "en"
    let status = await translationBroker.availability(from: from, to: to)
    switch status {
    case .unsupported:
      translationMessage = "This Mac cannot translate \(from) to \(to)."
      return
    case .supported:
      translationMessage =
        "Translation languages are not installed yet. macOS should offer a download."
    case .installed:
      translationMessage = "On-device translation."
    }
    var pending: [String] = []
    var index: [Int] = []
    for (offset, run) in textRuns.enumerated() {
      if LanguageDetect.isAlready(run.text, language: to) { continue }
      let key = TranslationCache.key(text: run.text, from: from, to: to)
      if let cached = await translationCache.value(for: key) {
        textRuns[offset].translation = cached
        continue
      }
      pending.append(run.text)
      index.append(offset)
    }
    guard !pending.isEmpty else { return }
    do {
      let translated = try await translationBroker.translate(batch: pending, from: from, to: to)
      for (slot, text) in zip(index, translated) {
        let key = TranslationCache.key(text: textRuns[slot].text, from: from, to: to)
        await translationCache.store(key, text)
        textRuns[slot].translation = text
      }
      if status != .installed {
        translationMessage = "On-device translation."
      }
    } catch {
      translationMessage = error.localizedDescription
    }
  }

  private func copyText(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    statusText = "Copied."
  }

  private func flutterEnvironment() -> [String: String] {
    var env = environment
    if let sdk = AndroidSDK.discover(environment: environment, home: home) {
      env["ANDROID_SDK_ROOT"] = sdk.path
      env["ANDROID_HOME"] = sdk.path
      let prefix = "\(sdk.path)/platform-tools:\(sdk.path)/emulator"
      env["PATH"] = prefix + ":" + (environment["PATH"] ?? "")
    }
    if let flutter = tool("flutter") {
      let bin = flutter.deletingLastPathComponent().path
      env["PATH"] = bin + ":" + (env["PATH"] ?? "")
    }
    return env
  }

  private func tool(_ name: String) -> URL? {
    locator.find(
      named: name,
      path: environment["PATH"] ?? "",
      extraDirectories: KnownTools.extraDirectories(for: name, home: home)
    )?.url
  }

  private static let authorizationKey = "QAWorkbench.authorizedUseAcknowledged"
}
