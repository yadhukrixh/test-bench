import Foundation
import WBCore
import WBFlutter

public actor HttpProfileSource {
  private let client: any VMCalling
  private let store: NetworkStore
  private var isolates: [String: Int] = [:]
  private var poller: Task<Void, Never>?
  private var watcher: Task<Void, Never>?
  private var running = false

  public init(client: any VMCalling, store: NetworkStore) {
    self.client = client
    self.store = store
  }

  public func start() async throws {
    await stop()
    running = true
    let stream = await client.events()
    watcher = Task { await self.watch(stream) }
    _ = try await client.call(
      method: VMProtocol.streamListen, params: ["streamId": "Isolate"])
    try await refreshIsolates()
    poller = Task { await self.poll() }
  }

  public func isolateCount() -> Int {
    isolates.count
  }

  public func refreshIsolates() async throws {
    let vm = try await client.call(method: VMProtocol.getVM, params: nil)
    let ids = VMProtocol.isolateIDs(fromVM: vm)
    var next: [String: Int] = [:]
    for id in ids {
      let isolate = try await client.call(
        method: VMProtocol.getIsolate, params: ["isolateId": id])
      guard VMProtocol.hasHttpProfile(isolate) else { continue }
      next[id] = isolates[id] ?? 0
      if isolates[id] == nil {
        _ = try await client.call(
          method: VMProtocol.httpEnableTimelineLogging,
          params: ["isolateId": id, "enabled": "true"]
        )
      }
    }
    isolates = next
  }

  public func clearProfile() async {
    for id in isolates.keys {
      _ = try? await client.call(
        method: VMProtocol.clearHttpProfile, params: ["isolateId": id])
    }
    await store.clear()
  }

  public func loadBodies(id: String) async throws -> NetworkBodies {
    if let existing = await store.bodies(id: id) { return existing }
    guard let event = await store.event(id: id) else {
      throw WBError(
        domain: .user, code: "network.missing", message: "That request is no longer in the list.")
    }
    let isolate = event.isolateId.isEmpty ? isolates.keys.first : event.isolateId
    guard let isolate else {
      throw WBError(
        domain: .source,
        code: "network.isolate",
        message: "No isolate is publishing an HTTP profile.",
        suggestion: "Run a debug Flutter project first."
      )
    }
    let data = try await client.call(
      method: VMProtocol.getHttpProfileRequest,
      params: ["isolateId": isolate, "id": id]
    )
    let bodies = HttpProfile.bodies(from: data)
    await store.storeBodies(id: id, bodies: bodies)
    return bodies
  }

  public func stop() async {
    running = false
    poller?.cancel()
    watcher?.cancel()
    poller = nil
    watcher = nil
    isolates = [:]
  }

  private func watch(_ stream: AsyncStream<VMEvent>) async {
    for await event in stream {
      if Task.isCancelled || !running { return }
      if event.isolatesChanged {
        try? await refreshIsolates()
      }
    }
  }

  private func poll() async {
    while running, !Task.isCancelled {
      if await !store.paused {
        if isolates.isEmpty {
          try? await refreshIsolates()
        }
        await pull()
      }
      try? await Task.sleep(for: .milliseconds(500))
    }
  }

  private func pull() async {
    for (isolate, since) in isolates {
      var params = ["isolateId": isolate]
      if since > 0 {
        params["updatedSince"] = String(since)
      }
      guard
        let data = try? await client.call(method: VMProtocol.getHttpProfile, params: params)
      else { continue }
      if let timestamp = HttpProfile.timestamp(from: data) {
        isolates[isolate] = timestamp
      }
      for event in HttpProfile.requests(from: data) {
        var next = event
        if next.isolateId.isEmpty { next.isolateId = isolate }
        await store.upsert(next)
        if next.state != .pending, await store.bodies(id: next.id) == nil {
          _ = try? await loadBodies(id: next.id)
        }
      }
    }
  }
}
