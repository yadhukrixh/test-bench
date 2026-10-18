import Foundation
import WBCore

public actor VMService: VMCalling {
  private var session: URLSession?
  private var task: URLSessionWebSocketTask?
  private var nextID = 1
  private var pending: [String: CheckedContinuation<Data, Error>] = [:]
  private var reader: Task<Void, Never>?
  private let bus = EventBus<VMEvent>()

  public init() {}

  public func events() async -> AsyncStream<VMEvent> {
    await bus.subscribe()
  }

  public func connect(_ wsUri: String) async throws {
    await disconnect()
    guard let url = URL(string: wsUri), let scheme = url.scheme?.lowercased(),
      scheme == "ws" || scheme == "wss"
    else {
      throw WBError(
        domain: .user,
        code: "vm.uri",
        message: "The Flutter debug port is not a WebSocket address.",
        suggestion: "Run the project again and wait for app.debugPort."
      )
    }
    let session = URLSession(configuration: .ephemeral)
    let task = session.webSocketTask(with: url)
    self.session = session
    self.task = task
    task.resume()
    reader = Task { await self.pump() }
    var last: Error?
    for _ in 0..<25 {
      do {
        _ = try await call(method: VMProtocol.getVM, params: nil)
        return
      } catch {
        last = error
        try? await Task.sleep(for: .milliseconds(200))
      }
    }
    throw WBError.wrap(
      last
        ?? WBError(
          domain: .source, code: "vm.connect", message: "The VM service did not answer getVM."),
      domain: .source,
      code: "vm.connect",
      message: "Could not open the Flutter VM service."
    )
  }

  public func disconnect() async {
    reader?.cancel()
    reader = nil
    task?.cancel(with: .goingAway, reason: nil)
    task = nil
    session?.invalidateAndCancel()
    session = nil
    let leftover = pending
    pending = [:]
    for continuation in leftover.values {
      continuation.resume(
        throwing: WBError(
          domain: .source, code: "vm.closed", message: "The VM service connection closed."))
    }
  }

  public func call(method: String, params: [String: String]?) async throws -> Data {
    guard let task else {
      throw WBError(
        domain: .source,
        code: "vm.idle",
        message: "The VM service is not connected.",
        suggestion: "Run the Flutter project first."
      )
    }
    let id = String(nextID)
    nextID += 1
    let payload = VMProtocol.request(id: id, method: method, params: params)
    let text = String(decoding: payload, as: UTF8.self)
    return try await withCheckedThrowingContinuation { continuation in
      pending[id] = continuation
      task.send(.string(text)) { error in
        if let error {
          Task { await self.fail(id: id, error: error) }
        }
      }
    }
  }

  private func fail(id: String, error: Error) {
    guard let continuation = pending.removeValue(forKey: id) else { return }
    continuation.resume(
      throwing: WBError.wrap(
        error, domain: .source, code: "vm.send", message: "The VM service call failed."))
  }

  private func pump() async {
    while let task, !Task.isCancelled {
      do {
        let message = try await task.receive()
        let data: Data
        switch message {
        case .data(let value):
          data = value
        case .string(let text):
          data = Data(text.utf8)
        @unknown default:
          continue
        }
        switch VMProtocol.parse(data) {
        case .response(let id, let result):
          pending.removeValue(forKey: id)?.resume(returning: result)
        case .failure(let id, let message):
          pending.removeValue(forKey: id)?.resume(
            throwing: WBError(domain: .source, code: "vm.rpc", message: message, retryable: true))
        case .event(let event):
          await bus.publish(event)
        case .ignored:
          break
        }
      } catch {
        let leftover = pending
        pending = [:]
        for continuation in leftover.values {
          continuation.resume(
            throwing: WBError.wrap(
              error, domain: .source, code: "vm.recv", message: "The VM service closed."))
        }
        break
      }
    }
  }
}
