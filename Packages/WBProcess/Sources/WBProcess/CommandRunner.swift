import Foundation
import WBCore

public struct CommandResult: Sendable, Equatable {
  public var status: Int32
  public var stdout: Data
  public var stderr: Data

  public init(status: Int32, stdout: Data, stderr: Data) {
    self.status = status
    self.stdout = stdout
    self.stderr = stderr
  }

  public init(status: Int32, stdout: String, stderr: String = "") {
    self.status = status
    self.stdout = Data(stdout.utf8)
    self.stderr = Data(stderr.utf8)
  }

  public var stdoutText: String {
    String(decoding: stdout, as: UTF8.self)
  }

  public var stderrText: String {
    String(decoding: stderr, as: UTF8.self)
  }
}

public protocol CommandExecuting: Sendable {
  func execute(
    executable: URL,
    arguments: [String],
    timeout: Duration,
    environment: [String: String]?
  ) async throws -> CommandResult
}

public struct SystemCommandRunner: CommandExecuting {
  public init() {}

  public func execute(
    executable: URL,
    arguments: [String],
    timeout: Duration,
    environment: [String: String]?
  ) async throws -> CommandResult {
    let managed = ManagedProcess()
    try managed.run(
      executable: executable,
      arguments: arguments,
      environment: environment,
      capture: .memory(cap: 8 * 1024 * 1024)
    )
    return try await withThrowingTaskGroup(of: CommandResult.self) { group in
      group.addTask {
        let status = await managed.waitForExit()
        return CommandResult(
          status: status,
          stdout: managed.capturedStdout(),
          stderr: managed.capturedStderr()
        )
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        managed.terminate()
        throw WBError(
          domain: .environment,
          code: "command.timeout",
          message: "\(executable.lastPathComponent) timed out.",
          suggestion: "Run it in Terminal to see where it stalls.",
          retryable: true
        )
      }
      guard let result = try await group.next() else {
        throw WBError(
          domain: .environment,
          code: "command.empty",
          message: "\(executable.lastPathComponent) produced no result."
        )
      }
      group.cancelAll()
      return result
    }
  }
}
