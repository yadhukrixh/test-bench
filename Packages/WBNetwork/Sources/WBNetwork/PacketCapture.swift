import Foundation

public enum PacketCapture {
  public static let listenHost = "127.0.0.1"
  public static let listenPort = 18081
  public static let packageName = "com.emanuelef.remote_capture"
  public static let component = "com.emanuelef.remote_capture/.activities.CaptureCtrl"
  public static let version = "v2.0.2"
  public static let apkURL = URL(
    string: "https://github.com/emanuele-f/PCAPdroid/releases/download/v2.0.2/PCAPdroid_v2.0.2.apk")!

  public static func startCommand(
    port: Int = listenPort, socksPort: Int = ProxyFlow.socksPort, appFilter: String? = nil,
    socks5: Bool = false
  ) -> [String] {
    var arguments = [
      "shell", "am", "start",
      "-n", component,
      "-e", "action", "start",
      "-e", "pcap_dump_mode", "tcp_exporter",
      "-e", "collector_host", "127.0.0.1",
      "-e", "collector_port", String(port),
      "-e", "socks5_enabled", socks5 ? "true" : "false",
      "-e", "socks5_proxy_host", "127.0.0.1",
      "-e", "socks5_proxy_port", String(socksPort),
      "-e", "tls_decryption", "false",
      "-e", "block_quic", "never",
      "-e", "full_payload", "true",
    ]
    if let appFilter, isCapturableApp(appFilter) {
      arguments.append(contentsOf: ["-e", "app_filter", appFilter])
    }
    return arguments
  }

  public static func capturePackage(foreground: String?, preferred: String?) -> String? {
    if let foreground, isCapturableApp(foreground) { return foreground }
    if let preferred, isCapturableApp(preferred) { return preferred }
    return nil
  }

  public static func consentIsVisible(_ windowDump: String) -> Bool {
    let lower = windowDump.lowercased()
    return lower.contains("vpndialogs") || lower.contains("com.android.vpndialogs")
  }

  public static func consentPoint(width: Int, height: Int) -> (x: Int, y: Int) {
    consentPoints(width: width, height: height)[0]
  }

  /// Taps for the system VPN confirmation (Allow / OK), newest layouts first.
  public static func consentPoints(width: Int, height: Int) -> [(x: Int, y: Int)] {
    [
      (max(width * 820 / 1080, 1), max(height * 1450 / 2400, 1)),
      (max(width * 770 / 1080, 1), max(height * 1392 / 2400, 1)),
    ]
  }

  public static func screenSize(in text: String) -> (width: Int, height: Int)? {
    for line in text.split(whereSeparator: \.isNewline) {
      guard line.contains("size:") else { continue }
      let value = line.split(separator: ":").last.map(String.init) ?? ""
      let parts = value.trimmingCharacters(in: .whitespaces).split(separator: "x")
      guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0,
        height > 0
      else { continue }
      return (width, height)
    }
    return nil
  }

  public static func isCapturableApp(_ name: String) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == packageName { return false }
    let blocked: Set<String> = [
      "android",
      "com.android.systemui",
      "com.android.launcher3",
      "com.google.android.apps.nexuslauncher",
      "com.google.android.gms",
    ]
    if blocked.contains(trimmed) || trimmed.hasPrefix("com.android.") { return false }
    return true
  }

  public static func stopCommand() -> [String] {
    [
      "shell", "am", "start",
      "-n", component,
      "-e", "action", "stop",
    ]
  }
}

public struct PcapStream: Sendable {
  private var buffer = Data()
  private var headerDone = false
  private var littleEndian = true
  private var linkType: UInt32 = 1
  private var inspector = PacketInspector()

  public init() {}

  public mutating func push(_ data: Data) -> [NetworkEvent] {
    buffer.append(data)
    if !headerDone {
      guard buffer.count >= 24 else { return [] }
      let magic = buffer.prefix(4)
      if magic == Data([0xD4, 0xC3, 0xB2, 0xA1]) {
        littleEndian = true
      } else if magic == Data([0xA1, 0xB2, 0xC3, 0xD4]) {
        littleEndian = false
      } else {
        buffer.removeAll()
        return []
      }
      linkType = u32(buffer, 20)
      buffer.removeSubrange(0..<24)
      headerDone = true
    }
    var events: [NetworkEvent] = []
    while buffer.count >= 16 {
      let included = Int(u32(buffer, 8))
      let seconds = Int(u32(buffer, 0))
      let micros = Int(u32(buffer, 4))
      guard included >= 0, included < 1_000_000 else {
        buffer.removeAll()
        break
      }
      guard buffer.count >= 16 + included else { break }
      let start = buffer.index(buffer.startIndex, offsetBy: 16)
      let end = buffer.index(start, offsetBy: included)
      let frame = Data(buffer[start..<end])
      buffer.removeSubrange(buffer.startIndex..<end)
      let timestamp = seconds * 1_000_000 + micros
      events.append(
        contentsOf: inspector.events(
          from: frame, linkType: linkType, timestampMicros: timestamp))
    }
    return events
  }

  private func u32(_ data: Data, _ offset: Int) -> UInt32 {
    let start = data.startIndex.advanced(by: offset)
    let bytes = [UInt8](data[start..<data.index(start, offsetBy: 4)])
    if littleEndian {
      return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3])
        << 24
    }
    return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8
      | UInt32(bytes[3])
  }
}

struct PacketInspector: Sendable {
  private var flows: [String: TCPFlow] = [:]

  private struct TCPFlow {
    var id: String
    var host: String
    var url: String
    var path: String
    var method = "CONNECT"
    var startMicros: Int
    var bytes: Int
    var hello = Data()
    var named = false
    var lastMicros = 0
  }

  mutating func events(from frame: Data, linkType: UInt32, timestampMicros: Int) -> [NetworkEvent] {
    let payload = Self.networkPayload(frame, linkType: linkType)
    guard let packet = Self.ipPayload(payload) else { return [] }
    if packet.proto == 17 {
      return Self.udpEvents(packet, timestampMicros: timestampMicros)
    }
    if packet.proto == 6 {
      return tcpEvents(packet, timestampMicros: timestampMicros)
    }
    return []
  }

  private struct IPPacket {
    var proto: UInt8
    var payload: Data
    var dstPort: Int
    var srcPort: Int
    var srcHost: String
    var dstHost: String
  }

  private static func networkPayload(_ frame: Data, linkType: UInt32) -> Data {
    if linkType == 1, frame.count >= 14 {
      let type =
        Int(frame[frame.startIndex.advanced(by: 12)]) << 8
        | Int(frame[frame.startIndex.advanced(by: 13)])
      if type == 0x0800 || type == 0x86DD {
        return Data(frame.dropFirst(14))
      }
    }
    if linkType == 113, frame.count >= 16 {
      return Data(frame.dropFirst(16))
    }
    if linkType == 101 || linkType == 12 || linkType == 276 {
      return frame
    }
    return frame
  }

  private static func ipPayload(_ data: Data) -> IPPacket? {
    guard data.count >= 20 else { return nil }
    let version = data[data.startIndex] >> 4
    if version == 4 {
      let ihl = Int(data[data.startIndex] & 0x0F) * 4
      guard ihl >= 20, data.count >= ihl else { return nil }
      let proto = data[data.startIndex.advanced(by: 9)]
      let src = dotted(data, 12)
      let dst = dotted(data, 16)
      let body = Data(data.dropFirst(ihl))
      return ports(proto: proto, body: body, srcHost: src, dstHost: dst)
    }
    if version == 6 {
      guard data.count >= 40 else { return nil }
      let proto = data[data.startIndex.advanced(by: 6)]
      let src = ipv6(data, 8)
      let dst = ipv6(data, 24)
      let body = Data(data.dropFirst(40))
      return ports(proto: proto, body: body, srcHost: src, dstHost: dst)
    }
    return nil
  }

  private static func dotted(_ data: Data, _ offset: Int) -> String {
    let start = data.startIndex.advanced(by: offset)
    return (0..<4).map { String(data[start.advanced(by: $0)]) }.joined(separator: ".")
  }

  private static func ipv6(_ data: Data, _ offset: Int) -> String {
    let start = data.startIndex.advanced(by: offset)
    return (0..<8).map { index in
      let high = data[start.advanced(by: index * 2)]
      let low = data[start.advanced(by: index * 2 + 1)]
      return String(format: "%x", Int(high) << 8 | Int(low))
    }.joined(separator: ":")
  }

  private static func ports(
    proto: UInt8, body: Data, srcHost: String, dstHost: String
  ) -> IPPacket? {
    guard body.count >= 4 else { return nil }
    let src = Int(body[body.startIndex]) << 8 | Int(body[body.startIndex.advanced(by: 1)])
    let dst =
      Int(body[body.startIndex.advanced(by: 2)]) << 8 | Int(body[body.startIndex.advanced(by: 3)])
    if proto == 17 {
      guard body.count >= 8 else { return nil }
      return IPPacket(
        proto: proto, payload: Data(body.dropFirst(8)), dstPort: dst, srcPort: src,
        srcHost: srcHost, dstHost: dstHost)
    }
    if proto == 6 {
      guard body.count >= 20 else { return nil }
      let offset = Int((body[body.startIndex.advanced(by: 12)] >> 4) * 4)
      guard offset >= 20, body.count >= offset else { return nil }
      return IPPacket(
        proto: proto, payload: Data(body.dropFirst(offset)), dstPort: dst, srcPort: src,
        srcHost: srcHost, dstHost: dstHost)
    }
    return IPPacket(
      proto: proto, payload: body, dstPort: dst, srcPort: src, srcHost: srcHost, dstHost: dstHost)
  }

  private static func udpEvents(_ packet: IPPacket, timestampMicros: Int) -> [NetworkEvent] {
    if packet.dstPort == 53 || packet.srcPort == 53, let name = dnsName(packet.payload) {
      return [
        event(
          id: "packet:dns:\(name):\(timestampMicros)",
          method: "DNS",
          url: "dns://\(name)",
          host: name,
          path: "",
          timestampMicros: timestampMicros
        )
      ]
    }
    return []
  }

  private mutating func tcpEvents(_ packet: IPPacket, timestampMicros: Int) -> [NetworkEvent] {
    if packet.payload.isEmpty { return [] }
    let key = Self.flowKey(packet)
    if flows.count > 2048 { flows.removeAll() }
    var flow =
      flows[key]
      ?? TCPFlow(
        id: "packet:tcp:\(key):\(timestampMicros)", host: "", url: "", path: "/",
        startMicros: timestampMicros, bytes: 0)
    flow.bytes += packet.payload.count
    let towardServer = [80, 443, 8080, 8443].contains(packet.dstPort)
    if towardServer, !flow.named {
      if flow.hello.count < 16_384 {
        flow.hello.append(packet.payload)
      }
      if let http = Self.httpRequest(flow.hello) {
        flow.named = true
        flow.method = http.method
        flow.host = http.host
        flow.url = http.url
        flow.path = http.path
        flow.id =
          "packet:http:\(http.method):\(http.host)\(http.path):\(packet.srcPort):\(flow.startMicros)"
        flow.lastMicros = timestampMicros
        flows[key] = flow
        return [
          Self.event(
            id: flow.id,
            method: http.method,
            url: http.url,
            host: http.host,
            path: http.path,
            timestampMicros: flow.startMicros,
            endMicros: timestampMicros,
            bytes: flow.bytes,
            headers: ["Host": [http.host]]
          )
        ]
      }
      if let host = Self.tlsSNI(flow.hello) {
        flow.named = true
        flow.method = "CONNECT"
        flow.host = host
        flow.url = "https://\(host)/"
        flow.path = "/"
        flow.id = "packet:tls:\(host):\(packet.srcPort):\(packet.dstPort):\(flow.startMicros)"
        flow.lastMicros = timestampMicros
        flows[key] = flow
        return [
          Self.event(
            id: flow.id,
            method: "CONNECT",
            url: flow.url,
            host: host,
            path: "/",
            timestampMicros: flow.startMicros,
            endMicros: timestampMicros,
            bytes: flow.bytes,
            headers: ["Host": [host]]
          )
        ]
      }
    }
    if flow.named {
      let burst =
        towardServer && flow.lastMicros > 0
        && timestampMicros - flow.lastMicros > 400_000
      flow.lastMicros = timestampMicros
      if burst {
        flow.id =
          "packet:\(flow.method == "CONNECT" ? "tls" : "http"):\(flow.host)\(flow.path):\(packet.srcPort):\(timestampMicros)"
        flow.startMicros = timestampMicros
        flow.bytes = packet.payload.count
      }
      flows[key] = flow
      return [
        Self.event(
          id: flow.id,
          method: flow.method,
          url: flow.url,
          host: flow.host,
          path: flow.path,
          timestampMicros: flow.startMicros,
          endMicros: timestampMicros,
          bytes: flow.bytes,
          headers: ["Host": [flow.host]]
        )
      ]
    }
    flow.lastMicros = timestampMicros
    flows[key] = flow
    return []
  }

  private static func flowKey(_ packet: IPPacket) -> String {
    let left = "\(packet.srcHost):\(packet.srcPort)"
    let right = "\(packet.dstHost):\(packet.dstPort)"
    return [left, right].sorted().joined(separator: "-")
  }

  private static func event(
    id: String, method: String, url: String, host: String, path: String, timestampMicros: Int,
    endMicros: Int? = nil, bytes: Int = 0, headers: [String: [String]] = [:]
  ) -> NetworkEvent {
    NetworkEvent(
      id: id,
      sources: [.packet],
      method: method,
      url: url,
      host: host,
      path: path,
      status: method == "CONNECT" || method == "DNS" ? 200 : nil,
      state: .complete,
      startMicros: timestampMicros,
      endMicros: endMicros ?? timestampMicros,
      requestHeaders: headers,
      requestBodySize: method == "CONNECT" ? 0 : bytes,
      responseBodySize: bytes
    )
  }

  private static func dnsName(_ data: Data) -> String? {
    guard data.count > 12 else { return nil }
    var index = 12
    var labels: [String] = []
    let bytes = [UInt8](data)
    while index < bytes.count {
      let length = Int(bytes[index])
      index += 1
      if length == 0 { break }
      if length & 0xC0 == 0xC0 {
        index += 1
        break
      }
      guard length < 64, index + length <= bytes.count else { return nil }
      labels.append(String(decoding: bytes[index..<(index + length)], as: UTF8.self))
      index += length
    }
    let name = labels.joined(separator: ".")
    return name.isEmpty ? nil : name
  }

  private static func tlsSNI(_ data: Data) -> String? {
    let bytes = [UInt8](data)
    var offset = 0
    while offset + 9 <= bytes.count {
      if bytes[offset] == 0x16 && bytes[offset + 1] == 0x03 {
        if let name = tlsSNI(from: Array(bytes[offset...])) { return name }
      }
      offset += 1
    }
    return nil
  }

  private static func tlsSNI(from bytes: [UInt8]) -> String? {
    guard bytes.count >= 9, bytes[0] == 0x16, bytes[5] == 0x01 else { return nil }
    var index = 5 + 4
    guard bytes.count > index + 2 + 32 else { return nil }
    index += 2 + 32
    guard index < bytes.count else { return nil }
    let sessionLen = Int(bytes[index])
    index += 1 + sessionLen
    guard index + 2 <= bytes.count else { return nil }
    let cipherLen = Int(bytes[index]) << 8 | Int(bytes[index + 1])
    index += 2 + cipherLen
    guard index < bytes.count else { return nil }
    let compLen = Int(bytes[index])
    index += 1 + compLen
    guard index + 2 <= bytes.count else { return nil }
    let extLen = Int(bytes[index]) << 8 | Int(bytes[index + 1])
    index += 2
    let end = min(bytes.count, index + extLen)
    while index + 4 <= end {
      let type = Int(bytes[index]) << 8 | Int(bytes[index + 1])
      let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
      index += 4
      guard index + length <= end else { return nil }
      if type == 0 {
        return sniName(Array(bytes[index..<(index + length)]))
      }
      index += length
    }
    return nil
  }

  private static func sniName(_ data: [UInt8]) -> String? {
    guard data.count >= 5 else { return nil }
    var index = 2
    while index + 3 <= data.count {
      let nameType = data[index]
      let length = Int(data[index + 1]) << 8 | Int(data[index + 2])
      index += 3
      guard index + length <= data.count else { return nil }
      if nameType == 0 {
        let name = String(decoding: data[index..<(index + length)], as: UTF8.self)
        return name.isEmpty ? nil : name
      }
      index += length
    }
    return nil
  }

  private static func httpRequest(_ data: Data) -> (
    method: String, host: String, path: String, url: String
  )? {
    guard let text = String(data: data.prefix(2048), encoding: .utf8) else { return nil }
    let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    let parts = first.split(separator: " ")
    guard parts.count >= 2 else { return nil }
    let method = String(parts[0])
    guard ["GET", "POST", "PUT", "HEAD", "DELETE", "PATCH", "OPTIONS"].contains(method) else {
      return nil
    }
    let path = String(parts[1])
    var host = ""
    for line in text.split(whereSeparator: \.isNewline) {
      let row = String(line)
      if row.lowercased().hasPrefix("host:") {
        host = row.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        break
      }
    }
    guard !host.isEmpty else { return nil }
    let url = path.hasPrefix("http") ? path : "http://\(host)\(path)"
    return (method, host, path.hasPrefix("http") ? (URL(string: path)?.path ?? "/") : path, url)
  }
}
