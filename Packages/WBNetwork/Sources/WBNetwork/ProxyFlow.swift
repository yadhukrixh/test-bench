import Foundation

public enum ProxyFlow {
  public static let maximumBodyBytes = 10 * 1024 * 1024
  public static let listenHost = "127.0.0.1"
  public static let listenPort = 18080
  public static let socksPort = 18082
  public static let guestAddress = "10.0.2.2:\(listenPort)"

  public static func parse(_ line: String) -> (NetworkEvent, NetworkBodies?)? {
    guard let data = line.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    let id = (object["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
    let method = (object["method"] as? String) ?? ""
    let url = (object["url"] as? String) ?? ""
    let parts = URL(string: url)
    let status = intValue(object["status"])
    let error = object["error"] as? String
    let state: NetworkState
    if let error, !error.isEmpty {
      state = .failed
    } else if status != nil {
      state = .complete
    } else {
      state = .pending
    }
    let responseHeaders = headers(object["response_headers"])
    let mime =
      (responseHeaders[header: "content-type"].first ?? "")
      .split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
    let requestBody = decodeBody(object["request_body"])
    let responseBody = decodeBody(object["response_body"])
    let truncated = (object["truncated"] as? Bool) ?? false
    let event = NetworkEvent(
      id: "proxy:\(id)",
      sources: [.proxy],
      method: method,
      url: url,
      host: parts?.host ?? "",
      path: parts?.path ?? "",
      status: status,
      state: state,
      startMicros: intValue(object["start"]) ?? 0,
      endMicros: intValue(object["end"]),
      requestHeaders: headers(object["request_headers"]),
      responseHeaders: responseHeaders,
      mimeType: mime,
      error: error,
      requestBodySize: requestBody.count,
      responseBodySize: responseBody.count,
      reasonPhrase: (object["reason"] as? String) ?? "",
      truncated: truncated
    )
    let bodies: NetworkBodies? =
      requestBody.isEmpty && responseBody.isEmpty
      ? nil : NetworkBodies(request: requestBody, response: responseBody, truncated: truncated)
    return (event, bodies)
  }

  public static let addon = """
    import base64
    import json
    import os
    import time

    from mitmproxy import http

    OUT = os.environ.get("WB_PROXY_EVENTS", "")
    MITM = os.environ.get("WB_PROXY_MITM", "") == "1"
    MAX = 10 * 1024 * 1024


    def emit(payload):
        if not OUT:
            return
        with open(OUT, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(payload, ensure_ascii=False) + "\\n")


    def hdr(headers):
        result = {}
        items = headers.items(multi=True) if hasattr(headers, "items") else []
        for key, value in items:
            result.setdefault(key, []).append(value)
        return result


    def body(raw):
        data = raw or b""
        truncated = len(data) > MAX
        if truncated:
            data = data[:MAX]
        return base64.b64encode(data).decode("ascii"), truncated


    def pretty(flow):
        if flow.request:
            return flow.request.pretty_url
        return ""


    def connect_url(flow):
        host = flow.request.host if flow.request else ""
        port = flow.request.port if flow.request else 0
        if port in (443, 0):
            return "https://%s/" % host
        if port == 80:
            return "http://%s/" % host
        return "https://%s:%s/" % (host, port)


    def dest_url(host, port):
        if port in (443, 0):
            return "https://%s/" % host
        if port == 80:
            return "http://%s/" % host
        return "https://%s:%s/" % (host, port)


    def emit_connect(host, port, ident):
        if not host:
            return
        emit({
            "id": ident or ("%s-%s" % (host, int(time.time() * 1000000))),
            "method": "CONNECT",
            "url": dest_url(host, port),
            "status": 200,
            "start": int(time.time() * 1000000),
            "request_headers": {"Host": [host]},
        })


    def api_host(host):
        name = (host or "").lower()
        return (
            "lookmeal" in name
            or "okinawa-navi" in name
            or "okinavi" in name
            or name.startswith("api.")
            or "graphql" in name
        )


    def tls_clienthello(data):
        host = ""
        port = 443
        try:
            host = (data.client_hello.sni or "") if data.client_hello else ""
        except Exception:
            host = ""
        server = getattr(getattr(data, "context", None), "server", None)
        address = getattr(server, "address", None) if server else None
        if address:
            if not host:
                host = address[0]
            if len(address) > 1:
                port = address[1]
        if MITM and api_host(host):
            return
        emit_connect(host, port, "")
        data.ignore_connection = True


    def tcp_start(flow):
        address = flow.server_conn.address if flow.server_conn else None
        if not address:
            return
        emit_connect(address[0], address[1], getattr(flow, "id", "") or "")


    def http_connect(flow: http.HTTPFlow):
        emit({
            "id": flow.id,
            "method": "CONNECT",
            "url": connect_url(flow),
            "status": 200,
            "start": int((flow.request.timestamp_start or time.time()) * 1000000),
            "request_headers": hdr(flow.request.headers) if flow.request else {},
        })


    def request(flow: http.HTTPFlow):
        if flow.request and flow.request.method == "CONNECT":
            return
        emit({
            "id": flow.id,
            "method": flow.request.method if flow.request else "",
            "url": pretty(flow),
            "start": int((flow.request.timestamp_start or time.time()) * 1000000),
            "request_headers": hdr(flow.request.headers) if flow.request else {},
        })


    def response(flow: http.HTTPFlow):
        if flow.request and flow.request.method == "CONNECT":
            return
        req_b, req_t = body(flow.request.content if flow.request else b"")
        res_b, res_t = body(flow.response.content if flow.response else b"")
        reason = ""
        if flow.response is not None:
            reason = getattr(flow.response, "reason", None) or ""
            if isinstance(reason, bytes):
                reason = reason.decode("utf-8", "replace")
        emit({
            "id": flow.id,
            "method": flow.request.method if flow.request else "",
            "url": pretty(flow),
            "status": flow.response.status_code if flow.response else None,
            "reason": reason,
            "start": int((flow.request.timestamp_start or 0) * 1000000),
            "end": int(((flow.response.timestamp_end if flow.response else None) or time.time()) * 1000000),
            "request_headers": hdr(flow.request.headers) if flow.request else {},
            "response_headers": hdr(flow.response.headers) if flow.response else {},
            "request_body": req_b,
            "response_body": res_b,
            "truncated": req_t or res_t,
        })


    def error(flow: http.HTTPFlow):
        emit({
            "id": flow.id,
            "method": flow.request.method if flow.request else "",
            "url": pretty(flow),
            "start": int(time.time() * 1000000),
            "error": str(getattr(flow, "error", None) or "proxy error"),
        })
    """

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

  private static func decodeBody(_ value: Any?) -> Data {
    guard let text = value as? String, !text.isEmpty,
      let data = Data(base64Encoded: text)
    else { return Data() }
    return data
  }

  private static func intValue(_ value: Any?) -> Int? {
    if let number = value as? Int { return number }
    if let number = value as? Int64 { return Int(number) }
    if let number = value as? NSNumber { return number.intValue }
    if let number = value as? Double { return Int(number) }
    if let text = value as? String { return Int(text) }
    return nil
  }
}
