import Foundation
import Testing
import WBProcess

@testable import WBInspect

struct HierarchyTests {
  @Test func stripsTheTrailerAndReadsBounds() throws {
    let xml = """
      <?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
      <hierarchy rotation="0">
        <node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="com.android.launcher3" content-desc="" checkable="false" checked="false" clickable="false" enabled="true" focusable="false" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[0,0][1080,2400]">
          <node index="0" text="" resource-id="" class="android.widget.TextView" package="com.android.launcher3" content-desc="Settings" checkable="false" checked="false" clickable="true" enabled="true" focusable="true" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[836,1905][1009,2100]" />
        </node>
      </hierarchy>
      UI hierchary dumped to: /dev/tty
      """
    #expect(UiAutomatorDump.arguments == ["exec-out", "uiautomator", "dump", "/dev/tty"])
    #expect(!UiAutomatorDump.xml(from: xml).contains("hierchary"))
    let root = try UiAutomatorDump.parse(xml)
    #expect(root.bounds.width == 1080)
    #expect(root.bounds.height == 2400)
    #expect(root.children.count == 1)
    #expect(root.children[0].contentDescription == "Settings")
    #expect(root.children[0].clickable)
    #expect(root.children[0].className == "android.widget.TextView")
    let hit = HitTest.node(atX: 922, y: 2002, in: root)
    #expect(hit?.contentDescription == "Settings")
    #expect(HitTest.node(atX: 10, y: 10, in: root)?.id == root.id)
    #expect(root.node(id: "0/0")?.contentDescription == "Settings")
  }

  @Test func prefersTheSmallerChild() {
    let inner = Node(
      id: "0/1",
      className: "android.widget.Button",
      text: "OK",
      bounds: NodeBounds(left: 100, top: 100, right: 200, bottom: 200),
      clickable: true
    )
    let root = Node(
      id: "0",
      className: "android.widget.FrameLayout",
      bounds: NodeBounds(left: 0, top: 0, right: 1080, bottom: 2400),
      children: [inner]
    )
    #expect(HitTest.node(atX: 150, y: 150, in: root)?.text == "OK")
    #expect(HitTest.clickable(matching: ["OK"], in: root)?.text == "OK")
    let allow = Node(
      id: "1",
      className: "android.widget.Button",
      package: "com.emanuelef.remote_capture",
      text: "ALLOW",
      bounds: NodeBounds(left: 540, top: 1329, right: 1001, bottom: 1455),
      clickable: true
    )
    let appOK = Node(
      id: "2",
      className: "android.widget.Button",
      package: "com.example.app",
      text: "OK",
      bounds: NodeBounds(left: 0, top: 0, right: 200, bottom: 80),
      clickable: true
    )
    let dialog = Node(
      id: "3",
      className: "android.widget.FrameLayout",
      bounds: NodeBounds(left: 0, top: 0, right: 1080, bottom: 2400),
      children: [appOK, allow]
    )
    #expect(
      HitTest.clickable(
        matching: ["OK", "ALLOW"],
        in: dialog,
        packages: ["com.emanuelef.remote_capture"]
      )?.text == "ALLOW")
  }
}

struct LiveDumpTests {
  @Test func dumpsARunningEmulatorWhenAsked() async throws {
    guard let serial = ProcessInfo.processInfo.environment["WB_ADB_SERIAL"] else { return }
    let adb =
      ProcessInfo.processInfo.environment["WB_ADB"]
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Android/sdk/platform-tools/adb").path
    let source = UiAutomatorSource(
      serial: serial,
      adb: URL(fileURLWithPath: adb),
      runner: LiveRunner()
    )
    let root = try await source.dump()
    #expect(root.bounds.width > 0)
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
