import Foundation

public enum HttpProfile {
  public static let maximumBodyBytes = 20 * 1024 * 1024

  public static func timestamp(from data: Data) -> Int? {
    guard let object = object(data) else { return nil }
    return intValue(object["timestamp"])
  }

  public static func requests(from data: Data) -> [NetworkEvent] {
    guard let object = object(data), let items = object["requests"] as? [Any] else { return [] }
    return items.compactMap { item in
      guard let request = item as? [String: Any] else { return nil }
      return event(from: request)
    }
  }

  public static func bodies(from data: Data) -> NetworkBodies {
    guard let object = object(data) else { return NetworkBodies() }
    let request = bytes(object["requestBody"])
    let response = bytes(object["responseBody"])
    let truncated = request.truncated || response.truncated
    return NetworkBodies(request: request.data, response: response.data, truncated: truncated)
  }

  public static func event(from request: [String: Any]) -> NetworkEvent? {
    let id: String
    if let text = request["id"] as? String, !text.isEmpty {
      id = text
    } else if let number = intValue(request["id"]) {
      id = String(number)
    } else {
      return nil
    }
    let method = (request["method"] as? String) ?? ""
    let url = (request["uri"] as? String) ?? ""
    let parts = URL(string: url)
    let response = request["response"] as? [String: Any] ?? [:]
    let requestInfo = request["request"] as? [String: Any] ?? [:]
    let status = intValue(response["statusCode"])
    let requestError = requestInfo["error"] as? String
    let responseError = response["error"] as? String
    let error = [requestError, responseError].compactMap { $0 }.first { !$0.isEmpty }
    let end = intValue(request["endTime"])
    let state: NetworkState
    if error != nil {
      state = .failed
    } else if end != nil, status != nil {
      state = .complete
    } else {
      state = .pending
    }
    let responseHeaders = headers(response["headers"])
    let mime =
      (responseHeaders[header: "content-type"].first ?? "")
      .split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces)
      ?? ""
    return NetworkEvent(
      id: id,
      sources: [.vm],
      method: method,
      url: url,
      host: parts?.host ?? "",
      path: parts?.path ?? (url.isEmpty ? "" : url),
      status: status,
      state: state,
      startMicros: intValue(request["startTime"]) ?? 0,
      endMicros: end,
      requestHeaders: headers(requestInfo["headers"]),
      responseHeaders: responseHeaders,
      mimeType: mime,
      error: error,
      requestBodySize: 0,
      responseBodySize: intValue(response["contentLength"]).map { max($0, 0) } ?? 0,
      reasonPhrase: (response["reasonPhrase"] as? String) ?? "",
      isolateId: (request["isolateId"] as? String) ?? "",
      compressionState: (response["compressionState"] as? String) ?? "",
      events: timings(request["events"])
    )
  }

  private static func timings(_ value: Any?) -> [NetworkTiming] {
    guard let items = value as? [Any] else { return [] }
    return items.compactMap { item in
      guard let object = item as? [String: Any], let name = object["event"] as? String else {
        return nil
      }
      return NetworkTiming(timestamp: intValue(object["timestamp"]) ?? 0, event: name)
    }
  }

  private static func headers(_ value: Any?) -> [String: [String]] {
    guard let object = value as? [String: Any] else { return [:] }
    var result: [String: [String]] = [:]
    for (key, raw) in object {
      if let values = raw as? [String] {
        result[key] = values
      } else if let values = raw as? [Any] {
        result[key] = values.compactMap { $0 as? String }
      } else if let text = raw as? String {
        result[key] = [text]
      }
    }
    return result
  }

  private static func bytes(_ value: Any?) -> (data: Data, truncated: Bool) {
    guard let items = value as? [Any] else { return (Data(), false) }
    let limit = min(items.count, maximumBodyBytes)
    var data = Data(capacity: limit)
    for item in items.prefix(limit) {
      if let number = item as? Int {
        data.append(UInt8(truncatingIfNeeded: number))
      } else if let number = item as? NSNumber {
        data.append(UInt8(truncatingIfNeeded: number.intValue))
      }
    }
    return (data, items.count > maximumBodyBytes)
  }

  private static func object(_ data: Data) -> [String: Any]? {
    guard let parsed = try? JSONSerialization.jsonObject(with: data) else { return nil }
    return unwrap(parsed)
  }

  private static func unwrap(_ value: Any) -> [String: Any]? {
    guard let object = value as? [String: Any] else { return nil }
    if object["requests"] != nil || object["requestBody"] != nil || object["timestamp"] != nil {
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

  private static func intValue(_ value: Any?) -> Int? {
    if let number = value as? Int { return number }
    if let number = value as? Int64 { return Int(number) }
    if let number = value as? NSNumber { return number.intValue }
    if let text = value as? String { return Int(text) }
    return nil
  }
}
