import Foundation
import Testing
import WBFlutter

@testable import WBNetwork

struct HttpProfileTests {
  @Test func readsProfileAndBodies() {
    let profile = Data(profileJSON.utf8)
    #expect(HttpProfile.timestamp(from: profile) == 1_791_971_185_300_000)
    let events = HttpProfile.requests(from: profile)
    #expect(events.count == 1)
    let event = events[0]
    #expect(event.id == "-683257686")
    #expect(event.method == "GET")
    #expect(event.url == "https://example.com/")
    #expect(event.host == "example.com")
    #expect(event.status == 200)
    #expect(event.state == .complete)
    #expect(event.sources == [.vm])
    #expect(event.compressionState == "HttpClientResponseCompressionState.decompressed")
    #expect(event.matches(filter: .doc, query: "example"))
    #expect(event.chromeName == "/")
    #expect(event.resourceType == .document)
    #expect(!event.matches(filter: .failed, query: ""))
    let detail = Data(detailJSON.utf8)
    let bodies = HttpProfile.bodies(from: detail)
    #expect(String(decoding: bodies.response, as: UTF8.self).hasPrefix("<!doctype html>"))
    #expect(bodies.request.isEmpty)
    let wrapped = Data(
      """
      {"type":"Success","json":{"type":"HttpProfile","timestamp":1,"requests":[{"id":"12","method":"POST","uri":"https://example.com/dart-io","startTime":1,"endTime":2,"response":{"statusCode":405,"reasonPhrase":"Method Not Allowed","headers":{"content-type":["application/json"]}}}]}}
      """.utf8)
    let posted = HttpProfile.requests(from: wrapped)
    #expect(posted.count == 1)
    #expect(posted[0].id == "12")
    #expect(posted[0].status == 405)
    #expect(
      HttpProfile.event(from: [
        "id": 99, "method": "GET", "uri": "https://example.com/", "startTime": 1,
      ])?.id == "99")
  }

  @Test func masksSecretsAndWritesHAR() async {
    let store = NetworkStore()
    var event = HttpProfile.requests(from: Data(profileJSON.utf8))[0]
    event.requestHeaders["Authorization"] = ["Bearer secret"]
    await store.upsert(event)
    await store.storeBodies(
      id: event.id,
      bodies: NetworkBodies(response: Data("<!doctype html>".utf8))
    )
    let har = String(decoding: await store.har(), as: UTF8.self)
    #expect(har.contains("\"version\" : \"1.2\""))
    #expect(har.contains("\"_source\" : \"vm\""))
    #expect(har.contains("••••"))
    #expect(!har.contains("Bearer secret"))
    let curl = CurlCommand.make(event, requestBody: Data(#"{"source":"dart:io"}"#.utf8))
    #expect(curl.contains("curl -X GET 'https://example.com/'"))
    #expect(curl.contains("-H 'Authorization: Bearer secret'"))
    #expect(HeaderRedaction.containsSecrets(event.requestHeaders))
  }

  @Test func pollsTheHTTPProfile() async throws {
    let vm = FakeVM()
    let store = NetworkStore()
    let source = HttpProfileSource(client: vm, store: store)
    try await source.start()
    try await Task.sleep(for: .milliseconds(50))
    let events = await store.snapshot()
    #expect(events.contains { $0.url == "https://example.com/" && $0.status == 200 })
    let calls = await vm.methods()
    #expect(calls.contains(VMProtocol.streamListen))
    #expect(calls.contains(VMProtocol.getVM))
    #expect(calls.contains(VMProtocol.getIsolate))
    #expect(calls.contains(VMProtocol.httpEnableTimelineLogging))
    #expect(calls.contains(VMProtocol.getHttpProfile))
    let enabled = await vm.params(for: VMProtocol.httpEnableTimelineLogging)
    #expect(enabled?["enabled"] == "true")
    let profile = await vm.params(for: VMProtocol.getHttpProfile)
    #expect(profile?["isolateId"] == "isolates/9")
    try await source.refreshIsolates()
    await source.stop()
  }

  @Test func parsesProxyLinesAndMergesSources() async throws {
    let line =
      #"{"id":"abc","method":"GET","url":"https://example.com/","status":200,"start":1791971183823422,"end":1791971185219505,"request_headers":{"user-agent":["okhttp"]},"response_headers":{"content-type":["text/html"]},"request_body":"","response_body":"PGh0bWw+","truncated":false}"#
    let parsed = try #require(ProxyFlow.parse(line))
    #expect(parsed.0.sources == [.proxy])
    #expect(parsed.0.status == 200)
    #expect(ProxyFlow.guestAddress == "10.0.2.2:18080")
    #expect(String(decoding: parsed.1?.response ?? Data(), as: UTF8.self) == "<html>")
    let killed = try #require(
      ProxyFlow.parse(
        #"{"id": "035395d9-5eb2-445d-8b56-bfb13d1c7f31", "method": "GET", "url": "http://127.0.0.1:18080/", "start": 1792040602240958, "error": "Connection killed: Request destination unknown. Unable to figure out where this request should be forwarded to."}"#
      ))
    #expect(killed.0.state == .failed)
    #expect(killed.0.host == "127.0.0.1")
    let store = NetworkStore()
    let vm = HttpProfile.requests(from: Data(profileJSON.utf8))[0]
    await store.upsert(vm)
    let storedID = await store.upsert(parsed.0)
    await store.storeBodies(id: storedID, bodies: parsed.1 ?? NetworkBodies())
    let all = await store.snapshot()
    #expect(all.count == 1)
    #expect(all[0].sources.contains(.vm))
    #expect(all[0].sources.contains(.proxy))
    #expect(all[0].id == vm.id)
    let bodies = await store.bodies(id: all[0].id)
    #expect(String(decoding: bodies?.response ?? Data(), as: UTF8.self) == "<html>")
    let connect = try #require(
      ProxyFlow.parse(
        #"{"id":"tls-1","method":"CONNECT","url":"https://example.com/","status":200,"start":1,"request_headers":{}}"#
      ))
    #expect(connect.0.method == "CONNECT")
    #expect(connect.0.host == "example.com")
    #expect(connect.0.sources == [.proxy])
    #expect(connect.0.resourceType == .other)
    #expect(!connect.0.matches(filter: .fetch, query: ""))
    #expect(connect.0.chromeName == "example.com")
    #expect(ProxyFlow.addon.contains("ignore_connection"))
    #expect(ProxyFlow.addon.contains("http_connect"))
    #expect(ProxyFlow.addon.contains("client_hello.sni"))
    #expect(ProxyFlow.addon.contains("tcp_start"))
    #expect(ProxyFlow.addon.contains("WB_PROXY_MITM"))
    #expect(ProxyFlow.addon.contains("lookmeal"))
    #expect(FlutterAPK.packScript.contains(".arsc"))
    #expect(ProxyFlow.socksPort == 18082)
    let lookmeal = NetworkEvent(
      id: "proxy:lookmeal",
      sources: [.proxy],
      method: "CONNECT",
      url: "https://qa.lookmeal.com/",
      host: "qa.lookmeal.com",
      path: "/",
      status: 200,
      state: .complete,
      startMicros: 1
    )
    #expect(lookmeal.isAPISession)
    #expect(lookmeal.matches(filter: .fetch, query: ""))
    let okinawa = NetworkEvent(
      id: "proxy:okinawa",
      sources: [.proxy],
      method: "CONNECT",
      url: "https://api.qa.okinawa-navi.jp/",
      host: "api.qa.okinawa-navi.jp",
      path: "/",
      status: 200,
      state: .complete,
      startMicros: 0
    )
    #expect(okinawa.isAPISession)
    #expect(ProxyFlow.addon.contains("okinawa-navi"))
    #expect(!connect.0.isAPISession)
    let apiHost = NetworkEvent(
      id: "packet:dns:api.qa.lookmeal.com",
      sources: [.packet],
      method: "DNS",
      url: "dns://api.qa.lookmeal.com",
      host: "api.qa.lookmeal.com",
      path: "",
      status: 200,
      state: .complete,
      startMicros: 2
    )
    #expect(apiHost.isAPISession)
    #expect(apiHost.matches(filter: .fetch, query: ""))
    let logged = try #require(
      LogcatHTTP.parse(
        #"D OkHttp: --> POST https://qa.lookmeal.com/api/v1/feed HTTP/1.1 status=200"#))
    #expect(logged.method == "POST")
    #expect(logged.url == "https://qa.lookmeal.com/api/v1/feed")
    #expect(logged.path == "/api/v1/feed")
    #expect(logged.status == 200)
    #expect(logged.sources == [.log])
    #expect(logged.matches(filter: .fetch, query: ""))
  }

  @Test func readsDNSAndTLSNamesFromAPCAPStream() {
    #expect(PacketCapture.listenPort == 18081)
    #expect(PacketCapture.startCommand().contains("tcp_exporter"))
    #expect(PacketCapture.startCommand().contains("socks5_enabled"))
    #expect(PacketCapture.startCommand().contains("false"))
    #expect(PacketCapture.startCommand().contains("18082"))
    #expect(PacketCapture.startCommand(socks5: true).contains("true"))
    #expect(
      PacketCapture.startCommand(appFilter: "com.allright.lookmeal").contains(
        "com.allright.lookmeal"))
    #expect(PacketCapture.packageName == "com.emanuelef.remote_capture")
    #expect(
      PacketCapture.capturePackage(
        foreground: "com.proalliance.okinavi", preferred: "com.allright.lookmeal")
        == "com.proalliance.okinavi")
    #expect(
      PacketCapture.capturePackage(
        foreground: "com.emanuelef.remote_capture", preferred: "com.allright.lookmeal")
        == "com.allright.lookmeal")
    #expect(
      PacketCapture.capturePackage(foreground: "com.android.systemui", preferred: nil) == nil)
    #expect(!PacketCapture.startCommand(appFilter: "com.android.systemui").contains("app_filter"))
    #expect(
      !PacketCapture.consentIsVisible(
        "mCurrentFocus=Window{u0 com.emanuelef.remote_capture/.activities.CaptureCtrl}"))
    #expect(
      PacketCapture.consentIsVisible(
        "mCurrentFocus=Window{u0 com.android.vpndialogs/.ConfirmDialog}"))
    #expect(
      !PacketCapture.consentIsVisible(
        "mCurrentFocus=Window{u0 com.proalliance.okinavi/.MainActivity}"))
    #expect(PacketCapture.screenSize(in: "Physical size: 1080x2400\n")?.width == 1080)
    #expect(PacketCapture.consentPoint(width: 1080, height: 2400) == (x: 820, y: 1450))
    var stream = PcapStream()
    var file = pcapHeader()
    file.append(
      pcapPacket(
        ethernetIPv4(proto: 17, payload: udp(port: 53, payload: dnsQuery("api.example.com")))))
    file.append(
      pcapPacket(
        ethernetIPv4(
          proto: 6,
          payload: tcp(payload: tlsClientHello(sni: "backend.example.com")))))
    file.append(
      pcapPacket(
        ethernetIPv4(
          proto: 6,
          payload: tcp(
            payload: Data("GET /v1 HTTP/1.1\r\nHost: clear.example.com\r\n\r\n".utf8),
            srcPort: 0x4444))))
    file.append(
      pcapPacket(
        ethernetIPv4(
          proto: 6,
          payload: tcp(payload: tlsClientHello(sni: "backend.example.com"), srcPort: 0x1234))))
    let events = stream.push(file)
    #expect(
      events.contains {
        $0.method == "DNS" && $0.host == "api.example.com" && $0.sources == [.packet]
      })
    #expect(
      events.contains {
        $0.method == "CONNECT" && $0.host == "backend.example.com"
          && $0.url == "https://backend.example.com/"
      })
    let gets = events.filter { $0.method == "GET" && $0.host == "clear.example.com" }
    #expect(gets.count == 1)
    #expect(gets[0].resourceType == .fetch)
    #expect(gets[0].matches(filter: .fetch, query: ""))
    #expect(gets[0].chromeName == "/v1")
    let tunnels = events.filter { $0.method == "CONNECT" && $0.host == "backend.example.com" }
    #expect(Set(tunnels.map(\.id)).count == 2)

    let hello = tlsClientHello(sni: "qa.lookmeal.com")
    var split = PcapStream()
    var splitFile = pcapHeader()
    splitFile.append(
      pcapPacket(ethernetIPv4(proto: 6, payload: tcp(payload: Data(hello.prefix(24))))))
    splitFile.append(
      pcapPacket(ethernetIPv4(proto: 6, payload: tcp(payload: Data(hello.dropFirst(24))))))
    let splitEvents = split.push(splitFile)
    #expect(splitEvents.contains { $0.method == "CONNECT" && $0.host == "qa.lookmeal.com" })

    var offsetHello = PcapStream()
    var offsetFile = pcapHeader()
    offsetFile.append(
      pcapPacket(
        ethernetIPv4(
          proto: 6, payload: tcp(payload: Data(repeating: 0, count: 4) + hello, srcPort: 0x2222))))
    #expect(
      offsetHello.push(offsetFile).contains {
        $0.method == "CONNECT" && $0.host == "qa.lookmeal.com"
      })

    var burst = PcapStream()
    var burstFile = pcapHeader()
    burstFile.append(
      pcapPacket(
        ethernetIPv4(
          proto: 6, payload: tcp(payload: hello, srcPort: 0x3333)),
        micros: 1_000))
    burstFile.append(
      pcapPacket(
        ethernetIPv4(
          proto: 6, payload: tcp(payload: Data([0x17, 0x03, 0x03, 0x00, 0x10]), srcPort: 0x3333)),
        micros: 50_000))
    burstFile.append(
      pcapPacket(
        ethernetIPv4(
          proto: 6, payload: tcp(payload: Data([0x17, 0x03, 0x03, 0x00, 0x20]), srcPort: 0x3333)),
        micros: 500_000))
    let burstEvents = burst.push(burstFile).filter {
      $0.method == "CONNECT" && $0.host == "qa.lookmeal.com"
    }
    #expect(Set(burstEvents.map(\.id)).count == 2)
    #expect(burstEvents[0].matches(filter: .fetch, query: ""))
  }

  @Test func patchesFlutterTLSVerifier() throws {
    #expect(
      FlutterTLS.libraryPath(in: [
        "lib/armeabi-v7a/libflutter.so", "lib/arm64-v8a/libflutter.so",
      ]) == "lib/arm64-v8a/libflutter.so")
    let elf = flutterVerifierELF()
    #expect(FlutterTLS.verifierOffset(in: elf) == 0x1000)
    #expect(!FlutterTLS.isBypassed(elf))
    let patched = try FlutterTLS.bypass(elf)
    #expect(FlutterTLS.isBypassed(patched))
    #expect(Data(patched[0x1000..<(0x1000 + 8)]) == FlutterTLS.trusted)
  }
}

private func flutterVerifierELF() -> Data {
  var data = Data(count: 0x3000)
  data[0] = 0x7F
  data[1] = 0x45
  data[2] = 0x4C
  data[3] = 0x46
  data[4] = 2
  data.replaceSubrange(16..<18, with: UInt16(3).littleEndianData)
  data.replaceSubrange(18..<20, with: UInt16(183).littleEndianData)
  data.replaceSubrange(32..<40, with: UInt64(64).littleEndianData)
  data.replaceSubrange(52..<54, with: UInt16(64).littleEndianData)
  data.replaceSubrange(54..<56, with: UInt16(56).littleEndianData)
  data.replaceSubrange(56..<58, with: UInt16(1).littleEndianData)
  data.replaceSubrange(64..<68, with: UInt32(1).littleEndianData)
  data.replaceSubrange(68..<72, with: UInt32(5).littleEndianData)
  data.replaceSubrange(72..<80, with: UInt64(0).littleEndianData)
  data.replaceSubrange(80..<88, with: UInt64(0).littleEndianData)
  data.replaceSubrange(96..<104, with: UInt64(data.count).littleEndianData)
  data.replaceSubrange(0x2000..<(0x2000 + 11), with: Data("ssl_client\u{0}".utf8))
  data.replaceSubrange(0x2010..<(0x2010 + 11), with: Data("ssl_server\u{0}".utf8))
  put32(&data, 0x1000, 0xD101_C3FF)
  put32(&data, 0x1004, 0xA901_7BFD)
  put32(&data, 0x1008, 0x3900_0048)
  put32(&data, 0x100C, adrp(rd: 0, pc: 0x100C, page: 0x2000))
  put32(&data, 0x1010, add64(rd: 0, rn: 0, imm: 0))
  put32(&data, 0x1014, adrp(rd: 1, pc: 0x1014, page: 0x2000))
  put32(&data, 0x1018, add64(rd: 1, rn: 1, imm: 0x10))
  return data
}

private func put32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
  var little = value.littleEndian
  withUnsafeBytes(of: &little) { data.replaceSubrange(offset..<(offset + 4), with: $0) }
}

private func adrp(rd: UInt32, pc: Int, page: Int) -> UInt32 {
  let imm = (page - (pc & ~0xFFF)) >> 12
  let immlo = UInt32(imm & 3)
  let immhi = UInt32((imm >> 2) & 0x7_FFFF)
  return 0x9000_0000 | (immlo << 29) | (immhi << 5) | rd
}

private func add64(rd: UInt32, rn: UInt32, imm: Int) -> UInt32 {
  0x9100_0000 | UInt32((imm & 0xFFF) << 10) | (rn << 5) | rd
}

extension UInt16 {
  fileprivate var littleEndianData: Data {
    var value = self.littleEndian
    return Data(bytes: &value, count: 2)
  }
}

extension UInt64 {
  fileprivate var littleEndianData: Data {
    var value = self.littleEndian
    return Data(bytes: &value, count: 8)
  }
}

private actor FakeVM: VMCalling {
  private var log: [(String, [String: String]?)] = []

  func call(method: String, params: [String: String]?) async throws -> Data {
    log.append((method, params))
    switch method {
    case VMProtocol.getVM:
      return Data(#"{"type":"VM","isolates":[{"id":"isolates/9","name":"main"}]}"#.utf8)
    case VMProtocol.getIsolate:
      return Data(
        #"{"type":"Isolate","id":"isolates/9","extensionRPCs":["ext.dart.io.getHttpProfile"]}"#
          .utf8)
    case VMProtocol.streamListen, VMProtocol.httpEnableTimelineLogging, VMProtocol.clearHttpProfile:
      return Data(#"{"type":"Success"}"#.utf8)
    case VMProtocol.getHttpProfile:
      return Data(profileJSON.utf8)
    case VMProtocol.getHttpProfileRequest:
      return Data(detailJSON.utf8)
    default:
      return Data(#"{}"#.utf8)
    }
  }

  func events() async -> AsyncStream<VMEvent> {
    AsyncStream { $0.finish() }
  }

  func methods() -> [String] {
    log.map(\.0)
  }

  func params(for method: String) -> [String: String]? {
    log.last { $0.0 == method }?.1
  }
}

private func pcapHeader() -> Data {
  Data([
    0xD4, 0xC3, 0xB2, 0xA1, 0x02, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xFF, 0xFF, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
  ])
}

private func pcapPacket(_ frame: Data, seconds: UInt32 = 0, micros: UInt32 = 0) -> Data {
  var header = Data(count: 16)
  header.replaceSubrange(0..<4, with: seconds.littleEndianData)
  header.replaceSubrange(4..<8, with: micros.littleEndianData)
  header.replaceSubrange(8..<12, with: UInt32(frame.count).littleEndianData)
  header.replaceSubrange(12..<16, with: UInt32(frame.count).littleEndianData)
  return header + frame
}

private func ethernetIPv4(proto: UInt8, payload: Data) -> Data {
  var ip = Data([0x45, 0, 0, 0, 0, 0, 0, 0, 64, proto, 0, 0, 10, 0, 2, 15, 1, 2, 3, 4])
  let total = UInt16(20 + payload.count)
  ip[2] = UInt8(total >> 8)
  ip[3] = UInt8(total & 0xFF)
  return Data(repeating: 0, count: 12) + Data([0x08, 0x00]) + ip + payload
}

private func udp(port: UInt16, payload: Data) -> Data {
  var header = Data(count: 8)
  header[2] = UInt8(port >> 8)
  header[3] = UInt8(port & 0xFF)
  let length = UInt16(8 + payload.count)
  header[4] = UInt8(length >> 8)
  header[5] = UInt8(length & 0xFF)
  return header + payload
}

private func tcp(payload: Data, srcPort: UInt16 = 0) -> Data {
  var header = Data(count: 20)
  header[0] = UInt8(srcPort >> 8)
  header[1] = UInt8(srcPort & 0xFF)
  header[2] = 0x01
  header[3] = 0xBB
  header[12] = 0x50
  header[13] = 0x18
  return header + payload
}

private func dnsQuery(_ name: String) -> Data {
  var data = Data([0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
  for label in name.split(separator: ".") {
    data.append(UInt8(label.utf8.count))
    data.append(contentsOf: label.utf8)
  }
  data.append(0)
  data.append(contentsOf: [0x00, 0x01, 0x00, 0x01])
  return data
}

private func tlsClientHello(sni: String) -> Data {
  let host = Data(sni.utf8)
  var name = Data([0x00])
  name.append(UInt8(host.count >> 8))
  name.append(UInt8(host.count & 0xFF))
  name.append(host)
  var list = Data([0x00, 0x00])
  list[0] = UInt8((name.count) >> 8)
  list[1] = UInt8(name.count & 0xFF)
  list.append(name)
  var ext = Data([0x00, 0x00, 0x00, 0x00])
  ext[2] = UInt8(list.count >> 8)
  ext[3] = UInt8(list.count & 0xFF)
  ext.append(list)
  var hello = Data([0x03, 0x03]) + Data(repeating: 1, count: 32) + Data([0x00])
  hello.append(contentsOf: [0x00, 0x02, 0x00, 0x2F, 0x01, 0x00])
  hello.append(UInt8(ext.count >> 8))
  hello.append(UInt8(ext.count & 0xFF))
  hello.append(ext)
  var handshake = Data([0x01, 0x00, 0x00, 0x00])
  handshake[1] = UInt8((hello.count >> 16) & 0xFF)
  handshake[2] = UInt8((hello.count >> 8) & 0xFF)
  handshake[3] = UInt8(hello.count & 0xFF)
  handshake.append(hello)
  var record = Data([0x16, 0x03, 0x01, 0x00, 0x00])
  record[3] = UInt8(handshake.count >> 8)
  record[4] = UInt8(handshake.count & 0xFF)
  record.append(handshake)
  return record
}

extension UInt32 {
  fileprivate var littleEndianData: Data {
    var value = self.littleEndian
    return Data(bytes: &value, count: 4)
  }
}

private let profileJSON = """
  {
    "type": "HttpProfile",
    "timestamp": 1791971185300000,
    "requests": [
      {
        "type": "@HttpProfileRequest",
        "id": "-683257686",
        "isolateId": "isolates/9",
        "method": "GET",
        "uri": "https://example.com/",
        "startTime": 1791971183823422,
        "endTime": 1791971185219505,
        "events": [{"timestamp": 1791971183823422, "event": "Connection established"}],
        "request": {
          "headers": {"user-agent": ["Dart/3.11 (dart:io)"]},
          "method": "GET",
          "uri": "https://example.com/"
        },
        "response": {
          "startTime": 1791971185247751,
          "statusCode": 200,
          "reasonPhrase": "OK",
          "compressionState": "HttpClientResponseCompressionState.decompressed",
          "contentLength": 577,
          "headers": {"content-type": ["text/html; charset=utf-8"]}
        }
      }
    ]
  }
  """

private let detailJSON = """
  {
    "type": "HttpProfileRequest",
    "id": "-683257686",
    "method": "GET",
    "uri": "https://example.com/",
    "request": {"headers": {}},
    "response": {
      "statusCode": 200,
      "compressionState": "HttpClientResponseCompressionState.decompressed",
      "headers": {"content-type": ["text/html; charset=utf-8"]}
    },
    "requestBody": [],
    "responseBody": [60, 33, 100, 111, 99, 116, 121, 112, 101, 32, 104, 116, 109, 108, 62]
  }
  """
