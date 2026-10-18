import Foundation
import Testing

@testable import WBFlutter

struct MachineProtocolTests {
  @Test func readsDebugPortAndAppId() {
    let text = """
      [{"event":"daemon.connected","params":{"version":"0.6.1","pid":12}}]
      [{"event":"app.start","params":{"appId":"abc-1","directory":"/tmp/app"}}]
      [{"event":"app.debugPort","params":{"appId":"abc-1","port":5555,"wsUri":"ws://127.0.0.1:5555/token/ws","baseUri":"http://127.0.0.1:5555/"}}]
      noise
      [{"id":1,"result":{"code":0,"message":"Reloaded 1 of 905 libraries"}}]
      """
    let messages = MachineProtocol.parse(text)
    #expect(messages.contains { $0.event == "daemon.connected" })
    #expect(messages.contains { $0.appId == "abc-1" && $0.event == "app.start" })
    #expect(messages.contains { $0.wsUri == "ws://127.0.0.1:5555/token/ws" })
    #expect(messages.contains { $0.id == 1 && $0.resultCode == 0 })
  }

  @Test func encodesRestartAndStop() {
    let reload = String(
      decoding: MachineProtocol.restart(id: 1, appId: "abc-1", fullRestart: false), as: UTF8.self)
    #expect(reload.contains("\"method\":\"app.restart\""))
    #expect(reload.contains("\"appId\":\"abc-1\""))
    #expect(reload.contains("\"fullRestart\":false"))
    #expect(reload.hasSuffix("\n"))
    let restart = String(
      decoding: MachineProtocol.restart(id: 2, appId: "abc-1", fullRestart: true), as: UTF8.self)
    #expect(restart.contains("\"fullRestart\":true"))
    let stop = String(decoding: MachineProtocol.stop(id: 3, appId: "abc-1"), as: UTF8.self)
    #expect(stop.contains("\"method\":\"app.stop\""))
    #expect(
      MachineProtocol.runArguments(device: "emulator-5554") == [
        "run", "--machine", "-d", "emulator-5554",
      ])
    #expect(
      MachineProtocol.attachArguments(device: "emulator-5554") == [
        "attach", "--machine", "-d", "emulator-5554",
      ])
  }

  @Test func parsesVMServiceFrames() {
    let vm = Data(
      """
      {"jsonrpc":"2.0","id":"1","result":{"type":"VM","isolates":[{"id":"isolates/9","name":"main"}]}}
      """.utf8)
    guard case .response(let id, let result) = VMProtocol.parse(vm) else {
      Issue.record("expected a response")
      return
    }
    #expect(id == "1")
    #expect(VMProtocol.isolateIDs(fromVM: result) == ["isolates/9"])
    let isolate = Data(
      """
      {"type":"Isolate","id":"isolates/9","extensionRPCs":["ext.dart.io.getHttpProfile","ext.flutter.inspector.show"]}
      """.utf8)
    #expect(VMProtocol.hasHttpProfile(isolate))
    #expect(
      !VMProtocol.hasHttpProfile(Data(#"{"extensionRPCs":["ext.flutter.inspector.show"]}"#.utf8)))
    let notify = Data(
      """
      {"method":"streamNotify","params":{"streamId":"Isolate","event":{"kind":"IsolateRunnable","isolate":{"id":"isolates/9"}}}}
      """.utf8)
    guard case .event(let event) = VMProtocol.parse(notify) else {
      Issue.record("expected an isolate event")
      return
    }
    #expect(event.isolatesChanged)
    #expect(event.isolateId == "isolates/9")
    let encoded = VMProtocol.request(
      id: "3", method: VMProtocol.httpEnableTimelineLogging,
      params: ["isolateId": "isolates/9", "enabled": "true"])
    let text = String(decoding: encoded, as: UTF8.self)
    #expect(text.contains("\"method\":\"ext.dart.io.httpEnableTimelineLogging\""))
    #expect(text.contains("\"enabled\":\"true\""))
    let wrapped = Data(
      """
      {"jsonrpc":"2.0","id":"4","result":{"type":"Success","json":{"type":"HttpProfile","requests":[]}}}
      """.utf8)
    guard case .response(_, let inner) = VMProtocol.parse(wrapped) else {
      Issue.record("expected a wrapped response")
      return
    }
    let object = (try? JSONSerialization.jsonObject(with: inner)) as? [String: Any]
    #expect(object?["type"] as? String == "HttpProfile")
  }

  @Test func recognizesAProject() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(!MachineProtocol.isProject(root))
    try "name: x\n".write(
      to: root.appendingPathComponent("pubspec.yaml"), atomically: true, encoding: .utf8)
    #expect(MachineProtocol.isProject(root))
  }
}
