import Foundation

public struct MachineMessage: Sendable, Equatable {
  public var event: String?
  public var id: Int?
  public var appId: String?
  public var wsUri: String?
  public var method: String?
  public var resultCode: Int?
  public var error: String?
  public var progress: String?

  public init(
    event: String? = nil,
    id: Int? = nil,
    appId: String? = nil,
    wsUri: String? = nil,
    method: String? = nil,
    resultCode: Int? = nil,
    error: String? = nil,
    progress: String? = nil
  ) {
    self.event = event
    self.id = id
    self.appId = appId
    self.wsUri = wsUri
    self.method = method
    self.resultCode = resultCode
    self.error = error
    self.progress = progress
  }
}

public enum MachineProtocol {
  public static func parse(_ text: String) -> [MachineMessage] {
    var found: [MachineMessage] = []
    for line in text.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("[") else { continue }
      guard let data = trimmed.data(using: .utf8),
        let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
      else { continue }
      for item in array {
        guard let object = item as? [String: Any] else { continue }
        found.append(message(from: object))
      }
    }
    return found
  }

  public static func restart(id: Int, appId: String, fullRestart: Bool) -> Data {
    command(
      id: id,
      method: "app.restart",
      params: [
        "appId": appId,
        "fullRestart": fullRestart,
        "pause": false,
        "debounce": false,
      ]
    )
  }

  public static func stop(id: Int, appId: String) -> Data {
    command(id: id, method: "app.stop", params: ["appId": appId])
  }

  public static func runArguments(device: String) -> [String] {
    ["run", "--machine", "-d", device]
  }

  public static func attachArguments(device: String) -> [String] {
    ["attach", "--machine", "-d", device]
  }

  public static func isProject(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.appendingPathComponent("pubspec.yaml").path)
  }

  private static func command(id: Int, method: String, params: [String: Any]) -> Data {
    let payload: [[String: Any]] = [
      ["id": id, "method": method, "params": params]
    ]
    let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    return data + Data("\n".utf8)
  }

  private static func message(from object: [String: Any]) -> MachineMessage {
    let params = object["params"] as? [String: Any] ?? [:]
    let result = object["result"] as? [String: Any] ?? [:]
    let error = object["error"] as? [String: Any]
    return MachineMessage(
      event: object["event"] as? String,
      id: object["id"] as? Int,
      appId: string(params["appId"]) ?? string(result["appId"]),
      wsUri: string(params["wsUri"]),
      method: object["method"] as? String,
      resultCode: result["code"] as? Int,
      error: string(error?["message"]) ?? string(object["error"]),
      progress: string(params["message"])
    )
  }

  private static func string(_ value: Any?) -> String? {
    if let text = value as? String, !text.isEmpty {
      return text
    }
    return nil
  }
}
