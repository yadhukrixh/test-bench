import Foundation
import WBCore

public enum CDPProtocol {
  public static let evaluate = "Runtime.evaluate"
  public static let snapshotExpression =
    "JSON.stringify({title:document.title,href:location.href,html:document.documentElement?document.documentElement.outerHTML:''})"

  public static func request(id: Int, method: String, expression: String) -> Data {
    let body: [String: Any] = [
      "id": id,
      "method": method,
      "params": [
        "expression": expression,
        "returnByValue": true,
      ],
    ]
    return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
  }

  public static func parse(_ data: Data) -> CDPMessage {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return .ignored
    }
    if let id = intValue(object["id"]) {
      if let error = object["error"] as? [String: Any] {
        let message = (error["message"] as? String) ?? "The DevTools call failed."
        return .failure(id: id, message: message)
      }
      let result = (try? JSONSerialization.data(withJSONObject: object["result"] ?? [:])) ?? Data()
      return .response(id: id, result: result)
    }
    return .ignored
  }

  public static func stringValue(from result: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: result) as? [String: Any] else {
      return nil
    }
    if let inner = object["result"] as? [String: Any] {
      if let value = inner["value"] as? String { return value }
      if let value = inner["description"] as? String { return value }
    }
    if let value = object["value"] as? String { return value }
    return nil
  }

  private static func intValue(_ value: Any?) -> Int? {
    if let number = value as? Int { return number }
    if let number = value as? NSNumber { return number.intValue }
    if let text = value as? String { return Int(text) }
    return nil
  }
}

public enum CDPMessage: Sendable, Equatable {
  case response(id: Int, result: Data)
  case failure(id: Int, message: String)
  case ignored
}

public actor CDPClient {
  private var session: URLSession?
  private var task: URLSessionWebSocketTask?
  private var nextID = 1
  private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
  private var reader: Task<Void, Never>?

  public init() {}

  public func connect(_ wsUri: String) async throws {
    await disconnect()
    guard let url = URL(string: wsUri), let scheme = url.scheme?.lowercased(),
      scheme == "ws" || scheme == "wss"
    else {
      throw WBError(
        domain: .user,
        code: "cdp.uri",
        message: "The DevTools page is not a WebSocket address.",
        suggestion: "Refresh the Web tab after a page is open."
      )
    }
    let session = URLSession(configuration: .ephemeral)
    let task = session.webSocketTask(with: url)
    self.session = session
    self.task = task
    task.resume()
    reader = Task { await self.pump() }
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
          domain: .source, code: "cdp.closed", message: "The DevTools connection closed."))
    }
  }

  public func evaluate(_ expression: String) async throws -> String {
    let data = try await call(method: CDPProtocol.evaluate, expression: expression)
    guard let value = CDPProtocol.stringValue(from: data) else {
      throw WBError(
        domain: .parse,
        code: "cdp.value",
        message: "The page did not return a string.",
        suggestion: "Refresh after the document has finished loading."
      )
    }
    return value
  }

  public func snapshot() async throws -> WebDocument {
    DevToolsTargets.document(from: try await evaluate(CDPProtocol.snapshotExpression))
  }

  private func call(method: String, expression: String) async throws -> Data {
    guard let task else {
      throw WBError(
        domain: .source,
        code: "cdp.idle",
        message: "The DevTools connection is not open.",
        suggestion: "Refresh the Web tab."
      )
    }
    let id = nextID
    nextID += 1
    let payload = CDPProtocol.request(id: id, method: method, expression: expression)
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

  private func fail(id: Int, error: Error) {
    guard let continuation = pending.removeValue(forKey: id) else { return }
    continuation.resume(
      throwing: WBError.wrap(
        error, domain: .source, code: "cdp.send", message: "The DevTools call failed."))
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
        switch CDPProtocol.parse(data) {
        case .response(let id, let result):
          pending.removeValue(forKey: id)?.resume(returning: result)
        case .failure(let id, let message):
          pending.removeValue(forKey: id)?.resume(
            throwing: WBError(domain: .source, code: "cdp.rpc", message: message, retryable: true))
        case .ignored:
          break
        }
      } catch {
        let leftover = pending
        pending = [:]
        for continuation in leftover.values {
          continuation.resume(
            throwing: WBError.wrap(
              error, domain: .source, code: "cdp.recv", message: "The DevTools connection closed."))
        }
        break
      }
    }
  }
}
