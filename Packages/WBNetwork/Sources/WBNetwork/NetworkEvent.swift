import Foundation

public enum NetworkOrigin: String, Sendable, Codable, Equatable {
  case vm
  case proxy
  case web
  case packet
  case log
}

public enum NetworkState: String, Sendable, Codable, Equatable {
  case pending
  case complete
  case failed
}

public enum NetworkFilter: String, Sendable, CaseIterable, Identifiable {
  case all = "All"
  case fetch = "Fetch/XHR"
  case doc = "Doc"
  case js = "JS"
  case css = "CSS"
  case img = "Img"
  case font = "Font"
  case ws = "WS"
  case other = "Other"
  case failed = "Failed"

  public var id: String { rawValue }
}

public enum NetworkResourceType: String, Sendable, Equatable {
  case fetch = "Fetch"
  case xhr = "XHR"
  case script = "JS"
  case stylesheet = "CSS"
  case image = "Img"
  case font = "Font"
  case document = "Doc"
  case websocket = "WS"
  case media = "Media"
  case other = "Other"
}

public struct NetworkEvent: Sendable, Codable, Equatable, Identifiable {
  public var id: String
  public var sources: [NetworkOrigin]
  public var method: String
  public var url: String
  public var host: String
  public var path: String
  public var status: Int?
  public var state: NetworkState
  public var startMicros: Int
  public var endMicros: Int?
  public var requestHeaders: [String: [String]]
  public var responseHeaders: [String: [String]]
  public var mimeType: String
  public var error: String?
  public var requestBodySize: Int
  public var responseBodySize: Int
  public var reasonPhrase: String
  public var isolateId: String
  public var compressionState: String
  public var truncated: Bool
  public var events: [NetworkTiming]

  public init(
    id: String,
    sources: [NetworkOrigin] = [.vm],
    method: String,
    url: String,
    host: String = "",
    path: String = "",
    status: Int? = nil,
    state: NetworkState = .pending,
    startMicros: Int,
    endMicros: Int? = nil,
    requestHeaders: [String: [String]] = [:],
    responseHeaders: [String: [String]] = [:],
    mimeType: String = "",
    error: String? = nil,
    requestBodySize: Int = 0,
    responseBodySize: Int = 0,
    reasonPhrase: String = "",
    isolateId: String = "",
    compressionState: String = "",
    truncated: Bool = false,
    events: [NetworkTiming] = []
  ) {
    self.id = id
    self.sources = sources
    self.method = method
    self.url = url
    self.host = host
    self.path = path
    self.status = status
    self.state = state
    self.startMicros = startMicros
    self.endMicros = endMicros
    self.requestHeaders = requestHeaders
    self.responseHeaders = responseHeaders
    self.mimeType = mimeType
    self.error = error
    self.requestBodySize = requestBodySize
    self.responseBodySize = responseBodySize
    self.reasonPhrase = reasonPhrase
    self.isolateId = isolateId
    self.compressionState = compressionState
    self.truncated = truncated
    self.events = events
  }

  public var durationMillis: Int? {
    guard let endMicros else { return nil }
    return max(endMicros - startMicros, 0) / 1000
  }

  public var resourceType: NetworkResourceType {
    let method = self.method.uppercased()
    if method == "CONNECT" || method == "DNS" { return .other }
    let mime = mimeType.lowercased()
    let path = self.path.lowercased()
    if requestHeaders[header: "upgrade"].contains(where: { $0.lowercased() == "websocket" })
      || responseHeaders[header: "upgrade"].contains(where: { $0.lowercased() == "websocket" })
    {
      return .websocket
    }
    if mime.contains("javascript") || path.hasSuffix(".js") { return .script }
    if mime.contains("css") || path.hasSuffix(".css") { return .stylesheet }
    if mime.hasPrefix("image/") { return .image }
    if mime.contains("font") || path.hasSuffix(".woff") || path.hasSuffix(".ttf") {
      return .font
    }
    if mime.hasPrefix("audio/") || mime.hasPrefix("video/") { return .media }
    if mime.contains("html") || mime.contains("pdf") { return .document }
    if mime.contains("json") || mime.contains("graphql") || path.contains("/api")
      || path.contains("graphql")
    {
      return .fetch
    }
    if ["POST", "PUT", "PATCH", "DELETE"].contains(method) { return .xhr }
    if mime.hasPrefix("text/") { return .document }
    let leaf = path.split(separator: "/").last.map(String.init) ?? ""
    if !leaf.contains("."), path.count > 1 {
      return .fetch
    }
    return .other
  }

  public var chromeName: String {
    if method.uppercased() == "CONNECT" || method.uppercased() == "DNS" {
      return host.isEmpty ? url : host
    }
    guard let parts = URL(string: url) else {
      return path.isEmpty ? url : path
    }
    var name = parts.path
    if name.isEmpty { name = "/" }
    if let query = parts.query, !query.isEmpty { name += "?\(query)" }
    return name
  }

  public var sizeLabel: String {
    let bytes = max(responseBodySize, requestBodySize)
    if bytes <= 0 { return "—" }
    if bytes < 1024 { return "\(bytes) B" }
    if bytes < 1024 * 1024 { return String(format: "%.1f kB", Double(bytes) / 1024) }
    return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
  }

  public var timeLabel: String {
    guard let durationMillis else { return "pending" }
    if durationMillis < 1000 { return "\(durationMillis) ms" }
    return String(format: "%.1f s", Double(durationMillis) / 1000)
  }

  public var statusLabel: String {
    if let status { return String(status) }
    if state == .failed { return "failed" }
    return "…"
  }

  public var isAPISession: Bool {
    let method = self.method.uppercased()
    guard method == "CONNECT" || method == "DNS" else { return false }
    let host = self.host.lowercased()
    return host.contains("lookmeal") || host.contains("okinawa-navi") || host.contains("okinavi")
      || host.hasPrefix("api.") || host.contains(".api.") || host.contains("graphql")
  }

  public func matches(filter: NetworkFilter, query: String) -> Bool {
    let haystack =
      "\(method) \(url) \(status.map(String.init) ?? "") \(host) \(path) \(resourceType.rawValue)"
      .lowercased()
    if !query.isEmpty, !haystack.contains(query.lowercased()) { return false }
    switch filter {
    case .all:
      return true
    case .fetch:
      return resourceType == .fetch || resourceType == .xhr || isAPISession
    case .doc:
      return resourceType == .document
    case .js:
      return resourceType == .script
    case .css:
      return resourceType == .stylesheet
    case .img:
      return resourceType == .image
    case .font:
      return resourceType == .font
    case .ws:
      return resourceType == .websocket
    case .other:
      return resourceType == .other || resourceType == .media
    case .failed:
      return state == .failed || (status ?? 0) >= 400
    }
  }
}

public struct NetworkTiming: Sendable, Codable, Equatable {
  public var timestamp: Int
  public var event: String

  public init(timestamp: Int, event: String) {
    self.timestamp = timestamp
    self.event = event
  }
}

public struct NetworkBodies: Sendable, Equatable {
  public var request: Data
  public var response: Data
  public var truncated: Bool

  public init(request: Data = Data(), response: Data = Data(), truncated: Bool = false) {
    self.request = request
    self.response = response
    self.truncated = truncated
  }
}

extension Dictionary where Key == String, Value == [String] {
  subscript(header name: String) -> [String] {
    let match = first { $0.key.lowercased() == name.lowercased() }
    return match?.value ?? []
  }
}

public enum HeaderRedaction {
  public static let names = [
    "authorization", "cookie", "set-cookie", "x-api-key", "token", "access-token", "refresh-token",
  ]

  public static func mask(_ headers: [String: [String]]) -> [String: [String]] {
    var copy = headers
    for key in copy.keys where names.contains(key.lowercased()) {
      copy[key] = ["••••"]
    }
    return copy
  }

  public static func containsSecrets(_ headers: [String: [String]]) -> Bool {
    headers.keys.contains { names.contains($0.lowercased()) }
  }
}
