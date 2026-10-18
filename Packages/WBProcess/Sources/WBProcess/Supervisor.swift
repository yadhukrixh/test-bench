import Foundation
import WBCore
import os

public struct RestartPolicy: Sendable, Equatable {
  public var maxAttempts: Int
  public var initial: Duration
  public var multiplier: Double
  public var maximum: Duration

  public init(maxAttempts: Int, initial: Duration, multiplier: Double, maximum: Duration) {
    self.maxAttempts = maxAttempts
    self.initial = initial
    self.multiplier = multiplier
    self.maximum = maximum
  }

  public static let never = RestartPolicy(
    maxAttempts: 1,
    initial: .zero,
    multiplier: 1,
    maximum: .zero
  )
}

public struct ProcessRequest: Sendable {
  public var executable: URL
  public var arguments: [String]
  public var label: String
  public var trackKind: String
  public var restart: RestartPolicy
  public var environment: [String: String]?

  public init(
    executable: URL,
    arguments: [String],
    label: String,
    trackKind: String,
    restart: RestartPolicy,
    environment: [String: String]? = nil
  ) {
    self.executable = executable
    self.arguments = arguments
    self.label = label
    self.trackKind = trackKind
    self.restart = restart
    self.environment = environment
  }
}

public enum TrackedKind {
  public static let emulator = "emulator"
  public static let mitmdump = "mitmdump"
  public static let flutter = "flutter"
  public static let all = [emulator, mitmdump, flutter]
}

public struct PidRecord: Codable, Sendable, Equatable {
  public var pid: Int32
  public var kind: String
  public var executable: String
  public var arguments: [String]
  public var label: String

  public init(pid: Int32, kind: String, executable: String, arguments: [String], label: String) {
    self.pid = pid
    self.kind = kind
    self.executable = executable
    self.arguments = arguments
    self.label = label
  }
}

public actor Supervisor {
  private let directory: URL
  private let clock: any WBClock
  private let log: Logger
  private var jobs: [UUID: Job] = [:]

  public init(directory: URL, clock: any WBClock = ContinuousClock()) {
    self.directory = directory
    self.clock = clock
    self.log = Logger(subsystem: "com.qaworkbench.process", category: "supervisor")
    let manager = FileManager.default
    try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
    try? manager.createDirectory(
      at: directory.appendingPathComponent("pids"), withIntermediateDirectories: true)
    try? manager.createDirectory(
      at: directory.appendingPathComponent("logs"), withIntermediateDirectories: true)
  }

  public func start(_ request: ProcessRequest) throws -> UUID {
    let id = UUID()
    let job = Job(request: request)
    jobs[id] = job
    do {
      try spawn(id, job)
    } catch {
      jobs[id] = nil
      throw error
    }
    job.task = Task { await self.monitor(id) }
    return id
  }

  public func cancelRestart(_ id: UUID) {
    jobs[id]?.cancelled = true
  }

  public func stop(_ id: UUID) async {
    guard let job = jobs[id] else { return }
    job.cancelled = true
    job.task?.cancel()
    job.managed?.terminate()
    let deadline = ContinuousClock().now.advanced(by: .seconds(3))
    while jobs[id] != nil {
      if ContinuousClock().now >= deadline {
        jobs[id]?.managed?.kill()
      }
      try? await Task.sleep(for: .milliseconds(20))
    }
  }

  public func stopAll() async {
    for id in jobs.keys {
      await stop(id)
    }
  }

  public func pid(for id: UUID) -> Int32? {
    guard let pid = jobs[id]?.managed?.pid(), pid > 0 else { return nil }
    return pid
  }

  public func waitUntilFinished(_ id: UUID, timeout: Duration = .seconds(5)) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while jobs[id] != nil {
      if clock.now >= deadline {
        return false
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return true
  }

  public func logURL(for id: UUID) -> URL {
    directory.appendingPathComponent("logs/\(id.uuidString).log")
  }

  private func spawn(_ id: UUID, _ job: Job) throws {
    let managed = ManagedProcess()
    let logURL = logURL(for: id)
    try managed.run(
      executable: job.request.executable,
      arguments: job.request.arguments,
      environment: job.request.environment,
      capture: .file(logURL, cap: 10 * 1024 * 1024)
    )
    job.managed = managed
    job.attempts += 1
    let record = PidRecord(
      pid: managed.pid(),
      kind: job.request.trackKind,
      executable: job.request.executable.path,
      arguments: job.request.arguments,
      label: job.request.label
    )
    let data = try JSONEncoder().encode(record)
    try data.write(to: pidURL(id), options: .atomic)
    log.info("started \(job.request.label, privacy: .public) pid \(managed.pid())")
  }

  private func monitor(_ id: UUID) async {
    defer {
      try? FileManager.default.removeItem(at: pidURL(id))
      jobs[id] = nil
    }
    while let job = jobs[id] {
      guard let managed = job.managed else { return }
      let status = await managed.waitForExit()
      log.info("\(job.request.label, privacy: .public) exited \(status)")
      if job.cancelled || Task.isCancelled || status == 0 {
        return
      }
      if job.attempts >= job.request.restart.maxAttempts {
        return
      }
      let delay = backoff(afterFailure: job.attempts, policy: job.request.restart)
      do {
        try await clock.sleep(for: delay)
      } catch {
        return
      }
      if job.cancelled || Task.isCancelled {
        return
      }
      do {
        try spawn(id, job)
      } catch {
        return
      }
    }
  }

  private func backoff(afterFailure attempt: Int, policy: RestartPolicy) -> Duration {
    var nanoseconds = Double(policy.initial.components.seconds) * 1_000_000_000
    nanoseconds += Double(policy.initial.components.attoseconds) / 1_000_000_000
    var steps = attempt - 1
    while steps > 0 {
      nanoseconds *= policy.multiplier
      steps -= 1
    }
    var cap = Double(policy.maximum.components.seconds) * 1_000_000_000
    cap += Double(policy.maximum.components.attoseconds) / 1_000_000_000
    if nanoseconds > cap {
      nanoseconds = cap
    }
    return .nanoseconds(Int64(nanoseconds))
  }

  private func pidURL(_ id: UUID) -> URL {
    directory.appendingPathComponent("pids/\(id.uuidString).json")
  }
}

private final class Job: @unchecked Sendable {
  let request: ProcessRequest
  var attempts = 0
  var cancelled = false
  var managed: ManagedProcess?
  var task: Task<Void, Never>?

  init(request: ProcessRequest) {
    self.request = request
  }
}
