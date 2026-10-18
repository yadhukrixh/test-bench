import Foundation

public enum LogcatHTTP {
  public static func parse(_ line: String, nowMicros: Int = 0) -> NetworkEvent? {
    guard let url = url(in: line) else { return nil }
    let parts = URL(string: url)
    let method = method(in: line)
    let host = parts?.host ?? ""
    let path = parts?.path ?? ""
    return NetworkEvent(
      id: "log:\(method):\(url)",
      sources: [.log],
      method: method,
      url: url,
      host: host,
      path: path.isEmpty ? "/" : path,
      status: status(in: line),
      state: .complete,
      startMicros: nowMicros,
      endMicros: nowMicros,
      mimeType: url.contains("json") || path.contains("/api") ? "application/json" : ""
    )
  }

  public static func url(in line: String) -> String? {
    guard let match = line.range(of: #"https?://[^\s"'<>]+"#, options: .regularExpression)
    else { return nil }
    var text = String(line[match])
    while let last = text.last, ",.);]".contains(last) { text.removeLast() }
    return text.isEmpty ? nil : text
  }

  public static func method(in line: String) -> String {
    let upper = line.uppercased()
    for name in ["POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "GET"] {
      if upper.contains(" \(name) ") || upper.contains("\(name) HTTP")
        || upper.contains("--> \(name)") || upper.hasPrefix("\(name) ")
      {
        return name
      }
    }
    return "GET"
  }

  public static func status(in line: String) -> Int? {
    let patterns = [#"HTTP/[0-9.]+ ([1-5][0-9]{2})"#, #"(?:status|code)[=: ]+([1-5][0-9]{2})"#]
    for pattern in patterns {
      guard let match = line.range(of: pattern, options: .regularExpression) else { continue }
      let text = String(line[match])
      if let code = text.split(whereSeparator: { !$0.isNumber }).last, let value = Int(code) {
        return value
      }
    }
    return nil
  }
}
