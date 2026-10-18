import Foundation

public struct VMEvent: Sendable, Equatable {
  public var stream: String
  public var kind: String
  public var isolateId: String?

  public init(stream: String, kind: String, isolateId: String? = nil) {
    self.stream = stream
    self.kind = kind
    self.isolateId = isolateId
  }

  public var isolatesChanged: Bool {
    stream == "Isolate"
      && (kind == "IsolateStart" || kind == "IsolateExit" || kind == "IsolateRunnable")
  }
}

public enum VMIncoming: Sendable, Equatable {
  case response(id: String, result: Data)
  case failure(id: String, message: String)
  case event(VMEvent)
  case ignored
}

public protocol VMCalling: Sendable {
  func call(method: String, params: [String: String]?) async throws -> Data
  func events() async -> AsyncStream<VMEvent>
}

public enum VMProtocol {
  public static let getVM = "getVM"
  public static let getIsolate = "getIsolate"
  public static let streamListen = "streamListen"
  public static let getVersion = "getVersion"
  public static let httpEnableTimelineLogging = "ext.dart.io.httpEnableTimelineLogging"
  public static let getHttpProfile = "ext.dart.io.getHttpProfile"
  public static let getHttpProfileRequest = "ext.dart.io.getHttpProfileRequest"
  public static let clearHttpProfile = "ext.dart.io.clearHttpProfile"

  public static func request(id: String, method: String, params: [String: String]?) -> Data {
    var object: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
    if let params {
      object["params"] = params
    }
    return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
  }

  public static func parse(_ data: Data) -> VMIncoming {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return .ignored
    }
    if let method = object["method"] as? String, method == "streamNotify",
      let params = object["params"] as? [String: Any]
    {
      let stream = params["streamId"] as? String ?? ""
      let event = params["event"] as? [String: Any] ?? [:]
      let isolate = event["isolate"] as? [String: Any]
      return .event(
        VMEvent(
          stream: stream,
          kind: event["kind"] as? String ?? "",
          isolateId: isolate?["id"] as? String ?? event["isolateId"] as? String
        )
      )
    }
    let id = stringID(object["id"])
    if let error = object["error"] as? [String: Any] {
      let message = (error["message"] as? String) ?? "VM service error"
      return .failure(id: id ?? "", message: message)
    }
    if let id, let result = object["result"] {
      let payload = (try? JSONSerialization.data(withJSONObject: unwrap(result))) ?? Data("{}".utf8)
      return .response(id: id, result: payload)
    }
    return .ignored
  }

  public static func isolateIDs(fromVM data: Data) -> [String] {
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      return []
    }
    let isolates = object["isolates"] as? [[String: Any]] ?? []
    return isolates.compactMap { stringID($0["id"]) }.filter { !$0.isEmpty }
  }

  public static func hasHttpProfile(_ isolate: Data) -> Bool {
    guard let object = (try? JSONSerialization.jsonObject(with: isolate)) as? [String: Any] else {
      return false
    }
    let rpcs =
      object["extensionRPCs"] as? [String]
      ?? (object["json"] as? [String: Any])?["extensionRPCs"] as? [String]
      ?? []
    return rpcs.contains(getHttpProfile)
  }

  public static func unwrap(_ value: Any) -> Any {
    guard let object = value as? [String: Any] else { return value }
    if object["requests"] != nil || object["isolates"] != nil || object["extensionRPCs"] != nil
      || object["requestBody"] != nil
    {
      return object
    }
    if let nested = object["json"] {
      if let text = nested as? String,
        let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8))
      {
        return unwrap(parsed)
      }
      return unwrap(nested)
    }
    return object
  }

  private static func stringID(_ value: Any?) -> String? {
    if let text = value as? String { return text }
    if let number = value as? Int { return String(number) }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
  }
}
