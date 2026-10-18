import Darwin
import Foundation

final class ManagedProcess: @unchecked Sendable {
  enum Capture: Sendable {
    case memory(cap: Int)
    case file(URL, cap: Int)
  }

  private let process = Process()
  private let stdoutPipe = Pipe()
  private let stderrPipe = Pipe()
  private let lock = NSLock()
  private var waiters: [CheckedContinuation<Int32, Never>] = []
  private var exited = false
  private var status: Int32 = 0
  private var stdoutBuffer = Data()
  private var stderrBuffer = Data()
  private var memoryCap = 0

  func run(
    executable: URL,
    arguments: [String],
    environment: [String: String]?,
    capture: Capture
  ) throws {
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.currentDirectoryURL = URL(fileURLWithPath: "/")
    if let environment {
      var merged = ProcessInfo.processInfo.environment
      for (key, value) in environment {
        merged[key] = value
      }
      process.environment = merged
    }
    switch capture {
    case .memory(let cap):
      memoryCap = cap
      drainToMemory(stdoutPipe.fileHandleForReading, isStdout: true)
      drainToMemory(stderrPipe.fileHandleForReading, isStdout: false)
    case .file(let url, let cap):
      drainToFile(stdoutPipe.fileHandleForReading, url: url, cap: cap)
      drainToFile(stderrPipe.fileHandleForReading, url: url, cap: cap)
    }
    process.terminationHandler = { [weak self] proc in
      self?.complete(proc.terminationStatus)
    }
    try process.run()
  }

  func waitForExit() async -> Int32 {
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

  func terminate() {
    if process.isRunning {
      process.terminate()
    }
  }

  func kill() {
    let pid = process.processIdentifier
    if pid > 0 {
      Darwin.kill(pid, SIGKILL)
    }
  }

  func pid() -> Int32 {
    process.processIdentifier
  }

  func capturedStdout() -> Data {
    lock.lock()
    defer { lock.unlock() }
    return stdoutBuffer
  }

  func capturedStderr() -> Data {
    lock.lock()
    defer { lock.unlock() }
    return stderrBuffer
  }

  private func complete(_ code: Int32) {
    lock.lock()
    exited = true
    status = code
    let pending = waiters
    waiters.removeAll()
    lock.unlock()
    for waiter in pending {
      waiter.resume(returning: code)
    }
  }

  private func drainToMemory(_ handle: FileHandle, isStdout: Bool) {
    handle.readabilityHandler = { [weak self] file in
      let data = file.availableData
      if data.isEmpty {
        file.readabilityHandler = nil
        return
      }
      self?.appendMemory(data, isStdout: isStdout)
    }
  }

  private func appendMemory(_ data: Data, isStdout: Bool) {
    lock.lock()
    defer { lock.unlock() }
    if isStdout {
      guard stdoutBuffer.count < memoryCap else { return }
      stdoutBuffer.append(data.prefix(memoryCap - stdoutBuffer.count))
    } else {
      guard stderrBuffer.count < memoryCap else { return }
      stderrBuffer.append(data.prefix(memoryCap - stderrBuffer.count))
    }
  }

  private func drainToFile(_ handle: FileHandle, url: URL, cap: Int) {
    handle.readabilityHandler = { file in
      let data = file.availableData
      if data.isEmpty {
        file.readabilityHandler = nil
        return
      }
      LogFile.append(data, to: url, cap: cap)
    }
  }
}

enum LogFile {
  private static let lock = NSLock()

  static func append(_ data: Data, to url: URL, cap: Int) {
    lock.lock()
    defer { lock.unlock() }
    let manager = FileManager.default
    if !manager.fileExists(atPath: url.path) {
      manager.createFile(atPath: url.path, contents: nil)
    }
    let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    guard size < cap else { return }
    guard let handle = FileHandle(forWritingAtPath: url.path) else { return }
    defer { try? handle.close() }
    do {
      try handle.seekToEnd()
      try handle.write(contentsOf: data.prefix(cap - size))
    } catch {
      return
    }
  }
}
