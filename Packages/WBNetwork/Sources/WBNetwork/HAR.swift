import Foundation

public enum HAR {
  public static func document(events: [NetworkEvent], bodies: [String: NetworkBodies]) -> Data {
    let entries: [[String: Any]] = events.map { event in
      let body = bodies[event.id]
      let started = Date(timeIntervalSince1970: Double(event.startMicros) / 1_000_000)
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      return [
        "startedDateTime": formatter.string(from: started),
        "time": event.durationMillis ?? 0,
        "request": [
          "method": event.method,
          "url": event.url,
          "httpVersion": "HTTP/1.1",
          "cookies": [] as [Any],
          "headers": headerList(HeaderRedaction.mask(event.requestHeaders)),
          "queryString": [] as [Any],
          "headersSize": -1,
          "bodySize": body?.request.count ?? event.requestBodySize,
          "postData": [
            "mimeType": event.requestHeaders[header: "content-type"].first
              ?? "application/octet-stream",
            "text": text(body?.request ?? Data()),
          ],
        ],
        "response": [
          "status": event.status ?? 0,
          "statusText": event.reasonPhrase,
          "httpVersion": "HTTP/1.1",
          "cookies": [] as [Any],
          "headers": headerList(HeaderRedaction.mask(event.responseHeaders)),
          "content": [
            "size": body?.response.count ?? event.responseBodySize,
            "mimeType": event.mimeType,
            "text": text(body?.response ?? Data()),
          ],
          "redirectURL": "",
          "headersSize": -1,
          "bodySize": body?.response.count ?? event.responseBodySize,
        ],
        "cache": [:] as [String: Any],
        "timings": [
          "send": 0,
          "wait": event.durationMillis ?? 0,
          "receive": 0,
        ],
        "_source": event.sources.map(\.rawValue).joined(separator: ","),
      ] as [String: Any]
    }
    let log: [String: Any] = [
      "log": [
        "version": "1.2",
        "creator": ["name": "QA Workbench", "version": "0.1.0"],
        "entries": entries,
      ]
    ]
    return
      (try? JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys]))
      ?? Data()
  }

  private static func headerList(_ headers: [String: [String]]) -> [[String: String]] {
    headers.flatMap { name, values in
      values.map { ["name": name, "value": $0] }
    }.sorted { ($0["name"] ?? "") < ($1["name"] ?? "") }
  }

  private static func text(_ data: Data) -> String {
    String(data: data, encoding: .utf8) ?? data.map { String(format: "%02x", $0) }.joined()
  }
}

public enum CurlCommand {
  public static func make(_ event: NetworkEvent, requestBody: Data?) -> String {
    var parts = ["curl", "-X", event.method, quoted(event.url)]
    let headers = event.requestHeaders.sorted { $0.key.lowercased() < $1.key.lowercased() }
    for (name, values) in headers {
      for value in values {
        parts.append(contentsOf: ["-H", quoted("\(name): \(value)")])
      }
    }
    if let requestBody, !requestBody.isEmpty {
      parts.append(contentsOf: [
        "--data-binary", quoted(String(decoding: requestBody, as: UTF8.self)),
      ])
    }
    return parts.joined(separator: " ")
  }

  private static func quoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
