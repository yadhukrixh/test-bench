import Foundation
import WBCore

public final class ManualClock: WBClock, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [Duration] = []

  public init() {}

  public func sleep(for duration: Duration) async throws {
    try Task.checkCancellation()
    remember(duration)
  }

  public func recordedSleeps() -> [Duration] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  private func remember(_ duration: Duration) {
    lock.lock()
    recorded.append(duration)
    lock.unlock()
  }
}
