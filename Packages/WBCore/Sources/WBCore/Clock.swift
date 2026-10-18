import Foundation

public protocol WBClock: Sendable {
  func sleep(for duration: Duration) async throws
}

extension ContinuousClock: WBClock {
  public func sleep(for duration: Duration) async throws {
    try await sleep(until: now.advanced(by: duration), tolerance: nil)
  }
}
