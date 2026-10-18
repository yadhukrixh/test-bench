import Foundation
import WBCore

public actor NetworkStore {
  public static let maximumEntries = 10_000

  private var events: [String: NetworkEvent] = [:]
  private var bodies: [String: NetworkBodies] = [:]
  private var order: [String] = []
  private let bus = EventBus<Int>()
  private var revision = 0
  public var paused = false

  public init() {}

  public func setPaused(_ value: Bool) {
    paused = value
  }

  public func changes() async -> AsyncStream<Int> {
    await bus.subscribe()
  }

  public func snapshot() -> [NetworkEvent] {
    order.compactMap { events[$0] }
  }

  public func event(id: String) -> NetworkEvent? {
    events[id]
  }

  public func bodies(id: String) -> NetworkBodies? {
    bodies[id]
  }

  public static let mergeWindowMicros = 250_000

  @discardableResult
  public func upsert(_ event: NetworkEvent) async -> String {
    var next = event
    if let existing = events[event.id] {
      next = merge(existing, next)
      events[event.id] = next
      await publish()
      return next.id
    }
    if let siblingID = order.first(where: { id in
      guard let existing = events[id] else { return false }
      return Self.sameFlow(existing, event)
    }), let sibling = events[siblingID] {
      let merged = merge(sibling, next)
      if merged.id != siblingID {
        events[siblingID] = nil
        if let bodies = bodies[siblingID] {
          self.bodies[merged.id] = bodies
          self.bodies[siblingID] = nil
        }
        if let index = order.firstIndex(of: siblingID) {
          order[index] = merged.id
        }
      }
      events[merged.id] = merged
      await publish()
      return merged.id
    }
    order.append(event.id)
    events[event.id] = next
    trim()
    await publish()
    return event.id
  }

  public static func sameFlow(_ a: NetworkEvent, _ b: NetworkEvent) -> Bool {
    guard a.method == b.method, a.url == b.url else { return false }
    if let left = a.status, let right = b.status, left != right { return false }
    return abs(a.startMicros - b.startMicros) <= mergeWindowMicros
  }

  private func merge(_ existing: NetworkEvent, _ incoming: NetworkEvent) -> NetworkEvent {
    var next = existing
    if incoming.sources.contains(.vm) {
      next.id = incoming.id
      next.isolateId = incoming.isolateId
      if !incoming.requestHeaders.isEmpty { next.requestHeaders = incoming.requestHeaders }
      if !incoming.responseHeaders.isEmpty { next.responseHeaders = incoming.responseHeaders }
      if incoming.status != nil { next.status = incoming.status }
      if !incoming.reasonPhrase.isEmpty { next.reasonPhrase = incoming.reasonPhrase }
      if incoming.responseBodySize > 0 { next.responseBodySize = incoming.responseBodySize }
      if incoming.requestBodySize > 0 { next.requestBodySize = incoming.requestBodySize }
    } else {
      if next.requestHeaders.isEmpty { next.requestHeaders = incoming.requestHeaders }
      if next.responseHeaders.isEmpty { next.responseHeaders = incoming.responseHeaders }
      if next.status == nil { next.status = incoming.status }
      if incoming.endMicros != nil { next.endMicros = incoming.endMicros }
    }
    for source in incoming.sources where !next.sources.contains(source) {
      next.sources.append(source)
    }
    if incoming.state == .failed || next.state == .failed {
      next.state = .failed
      next.error = incoming.error ?? next.error
    } else if incoming.state == .complete || next.state == .complete {
      next.state = .complete
    }
    if incoming.endMicros != nil { next.endMicros = incoming.endMicros ?? next.endMicros }
    if next.mimeType.isEmpty { next.mimeType = incoming.mimeType }
    return next
  }

  public func storeBodies(id: String, bodies next: NetworkBodies) async {
    bodies[id] = next
    if var event = events[id] {
      event.requestBodySize = next.request.count
      event.responseBodySize = next.response.count
      event.truncated = event.truncated || next.truncated
      events[id] = event
    }
    await publish()
  }

  public func clear() async {
    events = [:]
    bodies = [:]
    order = []
    await publish()
  }

  public func har(ids: [String]? = nil) -> Data {
    let selected = (ids ?? order).compactMap { events[$0] }
    return HAR.document(events: selected, bodies: bodies)
  }

  private func trim() {
    while order.count > Self.maximumEntries {
      let id = order.removeFirst()
      events[id] = nil
      bodies[id] = nil
    }
  }

  private func publish() async {
    revision += 1
    await bus.publish(revision)
  }
}
