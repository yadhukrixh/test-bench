import Foundation

public struct DevToolsPage: Sendable, Equatable, Identifiable {
  public var id: String
  public var socket: String
  public var targetID: String
  public var title: String
  public var url: String
  public var type: String
  public var description: String
  public var webSocketDebuggerURL: String

  public init(
    id: String,
    socket: String,
    targetID: String,
    title: String,
    url: String,
    type: String,
    description: String,
    webSocketDebuggerURL: String
  ) {
    self.id = id
    self.socket = socket
    self.targetID = targetID
    self.title = title
    self.url = url
    self.type = type
    self.description = description
    self.webSocketDebuggerURL = webSocketDebuggerURL
  }

  public var label: String {
    let heading = title.isEmpty ? url : title
    return heading.isEmpty ? targetID : heading
  }
}

public struct WebDocument: Sendable, Equatable {
  public var title: String
  public var url: String
  public var html: String

  public init(title: String, url: String, html: String) {
    self.title = title
    self.url = url
    self.html = html
  }
}

public enum DevToolsTargets {
  public static let maximumHTMLBytes = 64 * 1024

  public static func parse(_ data: Data, socket: String, port: Int) -> [DevToolsPage] {
    guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
    let rows: [[String: Any]]
    if let list = root as? [[String: Any]] {
      rows = list
    } else if let object = root as? [String: Any], let list = object["value"] as? [[String: Any]] {
      rows = list
    } else {
      return []
    }
    return rows.compactMap { row in
      let targetID = string(row["id"])
      guard !targetID.isEmpty else { return nil }
      let rawSocket = string(row["webSocketDebuggerUrl"])
      let ws = rewrite(rawSocket, port: port)
      guard !ws.isEmpty else { return nil }
      return DevToolsPage(
        id: "\(socket)/\(targetID)",
        socket: socket,
        targetID: targetID,
        title: string(row["title"]),
        url: string(row["url"]),
        type: string(row["type"]),
        description: string(row["description"]),
        webSocketDebuggerURL: ws
      )
    }
  }

  public static func rewrite(_ url: String, port: Int) -> String {
    guard var parts = URLComponents(string: url) else { return url }
    parts.host = "127.0.0.1"
    parts.port = port
    return parts.string ?? url
  }

  public static func document(from value: String) -> WebDocument {
    let trimmed = value.count > maximumHTMLBytes ? String(value.prefix(maximumHTMLBytes)) : value
    guard let data = value.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return WebDocument(title: "", url: "", html: trimmed)
    }
    var html = string(object["html"])
    if html.count > maximumHTMLBytes {
      html = String(html.prefix(maximumHTMLBytes))
    }
    return WebDocument(title: string(object["title"]), url: string(object["href"]), html: html)
  }

  private static func string(_ value: Any?) -> String {
    if let text = value as? String { return text }
    if let number = value as? NSNumber { return number.stringValue }
    return ""
  }
}
