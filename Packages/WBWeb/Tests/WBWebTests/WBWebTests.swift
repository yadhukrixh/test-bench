import Foundation
import Testing
import WBProcess

@testable import WBWeb

struct DevToolsSocketTests {
  @Test func readsChromeAndWebViewAndSkipsStetho() {
    let unix = """
      0000000000000000: 00000002 00000000 00010000 0001 01 20628 @stetho_com.google.android.apps.messaging_devtools_remote
      0000000000000000: 00000002 00000000 00010000 0001 01 50162 @chrome_devtools_remote
      0000000000000000: 00000002 00000000 00010000 0001 01 50162 @chrome_devtools_remote
      0000000000000000: 00000002 00000000 00010000 0001 01 88421 @webview_devtools_remote_4242
      0000000000000000: 00000003 00000000 00000000 0001 03 12113 @com.android.internal.os.WebViewZygoteInit/abc
      """
    let sockets = DevToolsSockets.parse(unix)
    #expect(sockets.map(\.name) == ["chrome_devtools_remote", "webview_devtools_remote_4242"])
    #expect(sockets[0].kind == .chrome)
    #expect(sockets[0].processID == nil)
    #expect(sockets[1].kind == .webview)
    #expect(sockets[1].processID == 4242)
  }
}

struct DevToolsTargetTests {
  @Test func readsTheRecordedChromeList() throws {
    let data = Data(
      """
      [{"description":"","devtoolsFrontendUrl":"https://chrome-devtools-frontend.appspot.com/inspector.html?ws=127.0.0.1:50162/devtools/page/0","id":"0","title":"Example Domain","type":"page","url":"https://example.com/","webSocketDebuggerUrl":"ws://127.0.0.1:50162/devtools/page/0"}]
      """.utf8)
    let pages = DevToolsTargets.parse(data, socket: "chrome_devtools_remote", port: 19222)
    #expect(pages.count == 1)
    #expect(pages[0].id == "chrome_devtools_remote/0")
    #expect(pages[0].title == "Example Domain")
    #expect(pages[0].url == "https://example.com/")
    #expect(pages[0].type == "page")
    #expect(pages[0].webSocketDebuggerURL == "ws://127.0.0.1:19222/devtools/page/0")
    #expect(pages[0].label == "Example Domain")
  }

  @Test func snapshotsJSONAndCapsHTML() {
    let html = String(repeating: "a", count: DevToolsTargets.maximumHTMLBytes + 20)
    let value =
      "{\"title\":\"Example Domain\",\"href\":\"https://example.com/\",\"html\":\"\(html)\"}"
    let document = DevToolsTargets.document(from: value)
    #expect(document.title == "Example Domain")
    #expect(document.url == "https://example.com/")
    #expect(document.html.count == DevToolsTargets.maximumHTMLBytes)
  }
}

struct CDPProtocolTests {
  @Test func buildsEvaluateAndReadsAString() throws {
    let payload = CDPProtocol.request(
      id: 1, method: CDPProtocol.evaluate, expression: "document.title")
    let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
    #expect(object?["method"] as? String == "Runtime.evaluate")
    let params = object?["params"] as? [String: Any]
    #expect(params?["expression"] as? String == "document.title")
    #expect(params?["returnByValue"] as? Bool == true)
    let result = Data(
      """
      {"result":{"type":"string","value":"Example Domain"}}
      """.utf8)
    #expect(CDPProtocol.stringValue(from: result) == "Example Domain")
    let message = CDPProtocol.parse(
      Data(
        """
        {"id":1,"result":{"result":{"type":"string","value":"Example Domain"}}}
        """.utf8))
    guard case .response(let id, let body) = message else {
      Issue.record("expected a response")
      return
    }
    #expect(id == 1)
    #expect(CDPProtocol.stringValue(from: body) == "Example Domain")
  }

  @Test func readsAnRPCError() {
    let message = CDPProtocol.parse(
      Data(
        """
        {"id":2,"error":{"code":-32601,"message":"Runtime.evaluate wasn't found"}}
        """.utf8))
    guard case .failure(let id, let text) = message else {
      Issue.record("expected a failure")
      return
    }
    #expect(id == 2)
    #expect(text.contains("Runtime.evaluate"))
  }
}

struct LiveWebTests {
  @Test func listsChromeExampleWhenAsked() async throws {
    guard let serial = ProcessInfo.processInfo.environment["WB_ADB_SERIAL"] else { return }
    let adb =
      ProcessInfo.processInfo.environment["WB_ADB"]
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Android/sdk/platform-tools/adb").path
    let inspector = WebInspector(
      serial: serial,
      adb: URL(fileURLWithPath: adb),
      runner: LiveRunner()
    )
    let pages = try await inspector.listPages()
    #expect(pages.contains { $0.url.contains("example.com") })
    if let page = pages.first(where: { $0.url.contains("example.com") }) {
      let document = try await inspector.inspect(page)
      #expect(document.title.contains("Example"))
      #expect(document.html.lowercased().contains("html"))
    }
    await inspector.close()
  }
}

private struct LiveRunner: CommandExecuting {
  func execute(
    executable: URL,
    arguments: [String],
    timeout: Duration,
    environment: [String: String]?
  ) async throws -> CommandResult {
    try await SystemCommandRunner().execute(
      executable: executable,
      arguments: arguments,
      timeout: timeout,
      environment: environment
    )
  }
}
