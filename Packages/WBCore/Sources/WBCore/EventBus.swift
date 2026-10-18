import Foundation

public actor EventBus<Event: Sendable> {
  private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]

  public init() {}

  public func subscribe() -> AsyncStream<Event> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<Event>.makeStream(
      bufferingPolicy: .bufferingOldest(64)
    )
    continuations[id] = continuation
    continuation.onTermination = { _ in
      Task { await self.remove(id) }
    }
    return stream
  }

  public func publish(_ event: Event) {
    for continuation in continuations.values {
      continuation.yield(event)
    }
  }

  private func remove(_ id: UUID) {
    continuations[id] = nil
  }
}
