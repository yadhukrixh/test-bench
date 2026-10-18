import Foundation
import Network
import WBCore

public actor PacketEngine {
  private let store: NetworkStore
  private var listener: NWListener?
  private var connections: [NWConnection] = []
  private var running = false

  public init(store: NetworkStore) {
    self.store = store
  }

  public func start() async throws {
    if running, listener != nil { return }
    await stop()
    guard let port = NWEndpoint.Port(rawValue: UInt16(PacketCapture.listenPort)) else {
      throw WBError(
        domain: .environment,
        code: "packet.port",
        message: "Could not listen for emulator packet capture."
      )
    }
    let parameters = NWParameters.tcp
    parameters.acceptLocalOnly = true
    let listener = try NWListener(using: parameters, on: port)
    listener.newConnectionHandler = { connection in
      Task { await self.accept(connection) }
    }
    try await Self.waitUntilReady(listener)
    self.listener = listener
    running = true
  }

  private static func waitUntilReady(_ listener: NWListener) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let once = ResumeOnce()
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          once.go { continuation.resume() }
        case .failed(let error):
          once.go {
            continuation.resume(
              throwing: WBError.wrap(
                error, domain: .source, code: "packet.listen",
                message: "Could not listen for emulator packet capture."))
          }
        case .cancelled:
          once.go {
            continuation.resume(
              throwing: WBError(
                domain: .source, code: "packet.listen",
                message: "Packet capture listen was cancelled."))
          }
        default:
          break
        }
      }
      listener.start(queue: DispatchQueue(label: "qa.workbench.packet"))
    }
  }

  public func stop() async {
    running = false
    listener?.cancel()
    listener = nil
    for connection in connections {
      connection.cancel()
    }
    connections = []
  }

  private func accept(_ connection: NWConnection) async {
    guard running else {
      connection.cancel()
      return
    }
    connections.append(connection)
    connection.start(queue: DispatchQueue(label: "qa.workbench.packet.conn"))
    await read(connection, stream: PcapStream())
  }

  private func read(_ connection: NWConnection, stream: PcapStream) async {
    var stream = stream
    while running {
      let chunk: Data? = await withCheckedContinuation { continuation in
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
          data, _, isComplete, _ in
          if let data, !data.isEmpty {
            continuation.resume(returning: data)
          } else if isComplete {
            continuation.resume(returning: nil)
          } else {
            continuation.resume(returning: Data())
          }
        }
      }
      guard let chunk else { break }
      if chunk.isEmpty { continue }
      let events = stream.push(chunk)
      for event in events {
        _ = await store.upsert(event)
      }
    }
    connection.cancel()
  }
}

private final class ResumeOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var done = false

  func go(_ body: () -> Void) {
    lock.lock()
    defer { lock.unlock() }
    if done { return }
    done = true
    body()
  }
}
