import Foundation
import WBCore
import WBProcess

public actor ProxyEngine {
  private let store: NetworkStore
  private var handle: UUID?
  private var supervisor: Supervisor?
  private var eventsURL: URL?
  private var tailer: Task<Void, Never>?
  private var running = false
  private var jumpToEnd = false

  public init(store: NetworkStore) {
    self.store = store
  }

  public func start(
    mitmdump: URL,
    supervisor: Supervisor,
    supportDirectory: URL,
    intercept: Bool = false
  ) async throws {
    await stop()
    let confdir = supportDirectory.appendingPathComponent("mitm", isDirectory: true)
    try FileManager.default.createDirectory(at: confdir, withIntermediateDirectories: true)
    let addon = confdir.appendingPathComponent("addon.py")
    try ProxyFlow.addon.write(to: addon, atomically: true, encoding: .utf8)
    let eventsURL = confdir.appendingPathComponent("events.jsonl")
    if !FileManager.default.fileExists(atPath: eventsURL.path) {
      try Data().write(to: eventsURL)
    }
    self.eventsURL = eventsURL
    self.supervisor = supervisor
    var environment = ProcessInfo.processInfo.environment
    environment["WB_PROXY_EVENTS"] = eventsURL.path
    if intercept {
      environment["WB_PROXY_MITM"] = "1"
    }
    var arguments = [
      "--mode", "regular@\(ProxyFlow.listenHost):\(ProxyFlow.listenPort)",
      "--mode", "socks5@\(ProxyFlow.listenHost):\(ProxyFlow.socksPort)",
      "--set", "confdir=\(confdir.path)",
      "-s", addon.path,
      "--quiet",
    ]
    if intercept {
      arguments.insert(contentsOf: ["--ssl-insecure"], at: 4)
    }
    let handle = try await supervisor.start(
      ProcessRequest(
        executable: mitmdump,
        arguments: arguments,
        label: "mitmdump",
        trackKind: TrackedKind.mitmdump,
        restart: RestartPolicy(
          maxAttempts: 2, initial: .seconds(1), multiplier: 2, maximum: .seconds(4)),
        environment: environment
      )
    )
    self.handle = handle
    running = true
    tailer = Task { await self.tail() }
  }

  public func skipToEnd() {
    jumpToEnd = true
  }

  public func stop() async {
    running = false
    tailer?.cancel()
    tailer = nil
    if let handle, let supervisor {
      await supervisor.cancelRestart(handle)
      await supervisor.stop(handle)
    }
    handle = nil
    supervisor = nil
  }

  private func tail() async {
    var offset = 0
    var leftover = ""
    while running, !Task.isCancelled, let eventsURL {
      if jumpToEnd {
        if let data = try? Data(contentsOf: eventsURL, options: [.uncached]) {
          offset = data.count
        }
        leftover = ""
        jumpToEnd = false
        try? await Task.sleep(for: .milliseconds(50))
        continue
      }
      if let data = try? Data(contentsOf: eventsURL, options: [.uncached]), data.count > offset {
        leftover += String(decoding: data[offset...], as: UTF8.self)
        offset = data.count
        var lines = leftover.split(
          separator: "\n", omittingEmptySubsequences: false
        ).map(String.init)
        leftover = lines.popLast() ?? ""
        for line in lines where !line.isEmpty {
          guard let parsed = ProxyFlow.parse(line) else { continue }
          let id = await store.upsert(parsed.0)
          if let bodies = parsed.1 {
            await store.storeBodies(id: id, bodies: bodies)
          }
        }
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
  }
}
