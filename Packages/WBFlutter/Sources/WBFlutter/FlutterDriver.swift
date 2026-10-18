import Foundation
import WBCore
import WBProcess

public struct FlutterSession: Sendable, Equatable {
  public var appId: String
  public var wsUri: String
}

public actor FlutterDriver {
  private var terminal: PseudoTerminal?
  private var appId: String?
  private var wsUri: String?
  private var nextID = 10
  private var pidURL: URL?
  private var reader: Task<Void, Never>?
  private var commandResults: [Int: Int] = [:]
  private let bus = EventBus<String>()

  public init() {}

  public func events() async -> AsyncStream<String> {
    await bus.subscribe()
  }

  public func session() -> FlutterSession? {
    guard let appId, let wsUri else { return nil }
    return FlutterSession(appId: appId, wsUri: wsUri)
  }

  public func start(
    project: URL,
    device: String,
    flutter: URL,
    supportDirectory: URL,
    environment: [String: String]?
  ) async throws -> FlutterSession {
    await stop()
    guard MachineProtocol.isProject(project) else {
      throw WBError(
        domain: .user,
        code: "flutter.project",
        message: "That folder is not a Flutter project.",
        suggestion: "Choose the folder that contains pubspec.yaml."
      )
    }
    return try await launch(
      arguments: MachineProtocol.runArguments(device: device),
      directory: project,
      flutter: flutter,
      device: device,
      supportDirectory: supportDirectory,
      environment: environment,
      timeout: .seconds(240)
    )
  }

  public func attach(
    project: URL?,
    device: String,
    flutter: URL,
    supportDirectory: URL,
    environment: [String: String]?,
    timeout: Duration = .seconds(90)
  ) async throws -> FlutterSession {
    await stop()
    let directory = project ?? FileManager.default.homeDirectoryForCurrentUser
    return try await launch(
      arguments: MachineProtocol.attachArguments(device: device),
      directory: directory,
      flutter: flutter,
      device: device,
      supportDirectory: supportDirectory,
      environment: environment,
      timeout: timeout
    )
  }

  private func launch(
    arguments: [String],
    directory: URL,
    flutter: URL,
    device: String,
    supportDirectory: URL,
    environment: [String: String]?,
    timeout: Duration
  ) async throws -> FlutterSession {
    let terminal = PseudoTerminal()
    try terminal.start(
      executable: flutter,
      arguments: arguments,
      directory: directory,
      environment: environment
    )
    self.terminal = terminal
    writePid(
      PidRecord(
        pid: terminal.pid(),
        kind: TrackedKind.flutter,
        executable: flutter.path,
        arguments: arguments,
        label: "flutter-\(device)"
      ),
      directory: supportDirectory
    )
    reader = Task { await self.pump(terminal) }
    let session = try await waitForDebugPort(timeout: timeout)
    await emit("Connected \(session.wsUri)")
    return session
  }

  public func hotReload() async throws {
    try await restart(full: false)
  }

  public func hotRestart() async throws {
    try await restart(full: true)
  }

  public func stop() async {
    if let appId, let terminal {
      try? terminal.write(MachineProtocol.stop(id: nextID, appId: appId))
      nextID += 1
      try? await Task.sleep(for: .seconds(1))
    }
    reader?.cancel()
    reader = nil
    terminal?.terminate()
    if let pid = terminal?.pid(), pid > 0 {
      try? await Task.sleep(for: .milliseconds(400))
      terminal?.kill()
    }
    terminal = nil
    appId = nil
    wsUri = nil
    commandResults = [:]
    if let pidURL {
      try? FileManager.default.removeItem(at: pidURL)
      self.pidURL = nil
    }
    await emit("Flutter stopped.")
  }

  private func restart(full: Bool) async throws {
    guard let appId, let terminal else {
      throw WBError(
        domain: .user,
        code: "flutter.idle",
        message: "Flutter is not running.",
        suggestion: "Run the project first."
      )
    }
    let id = nextID
    nextID += 1
    commandResults[id] = nil
    try terminal.write(MachineProtocol.restart(id: id, appId: appId, fullRestart: full))
    await emit(full ? "Hot restart…" : "Hot reload…")
    try await waitForCommand(id: id, timeout: .seconds(60))
  }

  private func waitForCommand(id: Int, timeout: Duration) async throws {
    let deadline = ContinuousClock().now.advanced(by: timeout)
    while ContinuousClock().now < deadline {
      if let code = commandResults[id] {
        if code == 0 { return }
        throw WBError(
          domain: .source,
          code: "flutter.restart",
          message: "Flutter reload did not succeed.",
          suggestion: "Read the Console tab for compiler output.",
          retryable: true
        )
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw WBError(
      domain: .source,
      code: "flutter.restart-timeout",
      message: "Flutter did not finish reload.",
      suggestion: "Wait until the app is running, then try again.",
      retryable: true
    )
  }

  private func waitForDebugPort(timeout: Duration) async throws -> FlutterSession {
    let deadline = ContinuousClock().now.advanced(by: timeout)
    while ContinuousClock().now < deadline {
      if let appId, let wsUri {
        return FlutterSession(appId: appId, wsUri: wsUri)
      }
      try await Task.sleep(for: .milliseconds(200))
    }
    throw WBError(
      domain: .source,
      code: "flutter.debugPort",
      message: "Flutter did not publish a debug port.",
      suggestion:
        "Use Run for a debug project, or Attach to an installed debug or profile APK. Release builds have no VM service.",
      retryable: true
    )
  }

  private func pump(_ terminal: PseudoTerminal) async {
    var leftover = ""
    for await chunk in terminal.bytes() {
      leftover += String(decoding: chunk, as: UTF8.self)
      let lines = leftover.split(separator: "\n", omittingEmptySubsequences: false)
      leftover = String(lines.last ?? "")
      let complete = lines.dropLast().joined(separator: "\n") + "\n"
      for message in MachineProtocol.parse(complete) {
        if let appId = message.appId {
          self.appId = appId
        }
        if let wsUri = message.wsUri {
          self.wsUri = wsUri
        }
        if let id = message.id, let code = message.resultCode {
          commandResults[id] = code
        }
        if let event = message.event {
          await emit(event + (message.progress.map { " \($0)" } ?? ""))
        } else if let error = message.error {
          await emit(error)
        }
      }
    }
  }

  private func emit(_ line: String) async {
    await bus.publish(line)
  }

  private func writePid(_ record: PidRecord, directory: URL) {
    let folder = directory.appendingPathComponent("pids", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("flutter.json")
    if let data = try? JSONEncoder().encode(record) {
      try? data.write(to: url, options: .atomic)
      pidURL = url
    }
  }
}
