import AppKit
import SwiftUI

@main
struct QAWorkbenchApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    Window("QA Workbench", id: "workbench") {
      WorkbenchView(model: AppModel.shared)
    }
    .defaultSize(width: 1200, height: 760)
    .commands {
      CommandGroup(replacing: .newItem) {}
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Task {
      await withTaskGroup(of: Void.self) { group in
        group.addTask { await AppModel.shared.shutdown() }
        group.addTask {
          try? await Task.sleep(for: .seconds(8))
        }
        _ = await group.next()
        group.cancelAll()
      }
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
