import Foundation
import WBProcess

public final class ScriptedCommandRunner: CommandExecuting, @unchecked Sendable {
  public struct Call: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]

    public init(executable: String, arguments: [String]) {
      self.executable = executable
      self.arguments = arguments
    }
  }

  private let lock = NSLock()
  private var recorded: [Call] = []
  private let respond: @Sendable (Call) -> CommandResult

  public init(respond: @escaping @Sendable (Call) -> CommandResult) {
    self.respond = respond
  }

  public func execute(
    executable: URL,
    arguments: [String],
    timeout: Duration,
    environment: [String: String]?
  ) async throws -> CommandResult {
    let call = Call(executable: executable.lastPathComponent, arguments: arguments)
    remember(call)
    return respond(call)
  }

  public func calls() -> [Call] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  private func remember(_ call: Call) {
    lock.lock()
    recorded.append(call)
    lock.unlock()
  }
}
