import Foundation
import WBCore
import WBProcess

public actor WebInspector {
  public static let basePort = 19222

  private let serial: String
  private let adb: URL
  private let runner: any CommandExecuting
  private var forwards: [String: Int] = [:]
  private var nextPort = WebInspector.basePort

  public init(serial: String, adb: URL, runner: any CommandExecuting) {
    self.serial = serial
    self.adb = adb
    self.runner = runner
  }

  public func listPages() async throws -> [DevToolsPage] {
    let unix = try await shell(["cat", "/proc/net/unix"])
    let sockets = DevToolsSockets.parse(unix)
    var pages: [DevToolsPage] = []
    for socket in sockets {
      let port = try await ensureForward(socket.name)
      guard let data = try await fetch(path: "/json/list", port: port) else { continue }
      pages.append(contentsOf: DevToolsTargets.parse(data, socket: socket.name, port: port))
    }
    return pages
  }

  public func inspect(_ page: DevToolsPage) async throws -> WebDocument {
    let port = try await ensureForward(page.socket)
    let client = CDPClient()
    try await client.connect(DevToolsTargets.rewrite(page.webSocketDebuggerURL, port: port))
    do {
      let document = try await client.snapshot()
      await client.disconnect()
      return document
    } catch {
      await client.disconnect()
      throw error
    }
  }

  public func close() async {
    let ports = Array(forwards.values)
    forwards = [:]
    for port in ports {
      _ = try? await run(["forward", "--remove", "tcp:\(port)"])
    }
  }

  private func ensureForward(_ name: String) async throws -> Int {
    if let port = forwards[name] { return port }
    let port = nextPort
    nextPort += 1
    let result = try await run(["forward", "tcp:\(port)", "localabstract:\(name)"])
    guard result.status == 0 else {
      throw WBError(
        domain: .device,
        code: "adb.forward",
        message: "Could not forward the DevTools socket to this Mac.",
        suggestion: result.stderrText + result.stdoutText,
        retryable: true
      )
    }
    forwards[name] = port
    return port
  }

  private func fetch(path: String, port: Int) async throws -> Data? {
    guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
    var request = URLRequest(url: url)
    request.timeoutInterval = 3
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
        return nil
      }
      return data
    } catch {
      return nil
    }
  }

  private func shell(_ arguments: [String]) async throws -> String {
    let result = try await run(["shell"] + arguments)
    return result.stdoutText + result.stderrText
  }

  private func run(_ arguments: [String]) async throws -> CommandResult {
    var args = ["-s", serial]
    args.append(contentsOf: arguments)
    return try await runner.execute(
      executable: adb,
      arguments: args,
      timeout: .seconds(15),
      environment: nil
    )
  }
}
