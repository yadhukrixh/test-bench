import Darwin
import Foundation
import WBCore

public final class PseudoTerminal: @unchecked Sendable {
  private let process = Process()
  private let lock = NSLock()
  private var master: FileHandle?
  private var waiters: [CheckedContinuation<Int32, Never>] = []
  private var exited = false
  private var status: Int32 = 0

  public init() {}

  public func start(
    executable: URL,
    arguments: [String],
    directory: URL,
    environment: [String: String]?
  ) throws {
    let masterFD = posix_openpt(O_RDWR | O_NOCTTY)
    guard masterFD >= 0 else {
      throw WBError(
        domain: .environment,
        code: "pty.open",
        message: "Could not open a pseudo-terminal."
      )
    }
    guard grantpt(masterFD) == 0, unlockpt(masterFD) == 0 else {
      Darwin.close(masterFD)
      throw WBError(
        domain: .environment,
        code: "pty.grant",
        message: "Could not set up the pseudo-terminal."
      )
    }
    var name = [CChar](repeating: 0, count: 128)
    guard ptsname_r(masterFD, &name, name.count) == 0 else {
      Darwin.close(masterFD)
      throw WBError(
        domain: .environment,
        code: "pty.name",
        message: "Could not name the pseudo-terminal."
      )
    }
    let slavePath = name.withUnsafeBufferPointer { buffer in
      String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    let slaveFD = open(slavePath, O_RDWR | O_NOCTTY)
    guard slaveFD >= 0 else {
      Darwin.close(masterFD)
      throw WBError(
        domain: .environment,
        code: "pty.slave",
        message: "Could not open the pseudo-terminal slave."
      )
    }
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = directory
    var merged = ProcessInfo.processInfo.environment
    if let environment {
      for (key, value) in environment {
        merged[key] = value
      }
    }
    merged["TERM"] = "xterm-256color"
    process.environment = merged
    let slave = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
    process.standardInput = slave
    process.standardOutput = slave
    process.standardError = slave
    process.terminationHandler = { [weak self] proc in
      self?.finish(proc.terminationStatus)
    }
    do {
      try process.run()
    } catch {
      Darwin.close(slaveFD)
      Darwin.close(masterFD)
      throw error
    }
    Darwin.close(slaveFD)
    master = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
  }

  public func write(_ data: Data) throws {
    guard let master else {
      throw WBError(domain: .environment, code: "pty.write", message: "The terminal is closed.")
    }
    try master.write(contentsOf: data)
  }

  public func bytes() -> AsyncStream<Data> {
    AsyncStream { continuation in
      self.master?.readabilityHandler = { handle in
        let data = handle.availableData
        if data.isEmpty {
          handle.readabilityHandler = nil
          continuation.finish()
        } else {
          continuation.yield(data)
        }
      }
      continuation.onTermination = { _ in
        self.master?.readabilityHandler = nil
      }
    }
  }

  public func waitForExit() async -> Int32 {
    await withCheckedContinuation { continuation in
      lock.lock()
      if exited {
        let code = status
        lock.unlock()
        continuation.resume(returning: code)
      } else {
        waiters.append(continuation)
        lock.unlock()
      }
    }
  }

  public func terminate() {
    if process.isRunning {
      process.terminate()
    }
  }

  public func kill() {
    let pid = process.processIdentifier
    if pid > 0 {
      Darwin.kill(pid, SIGKILL)
    }
  }

  public func pid() -> Int32 {
    process.processIdentifier
  }

  private func finish(_ code: Int32) {
    lock.lock()
    exited = true
    status = code
    let pending = waiters
    waiters.removeAll()
    lock.unlock()
    master?.readabilityHandler = nil
    for waiter in pending {
      waiter.resume(returning: code)
    }
  }
}
