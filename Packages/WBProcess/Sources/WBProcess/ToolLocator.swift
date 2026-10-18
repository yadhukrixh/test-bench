import Foundation
import WBCore

public struct ToolHit: Sendable, Equatable {
  public var url: URL
  public var onPath: Bool

  public init(url: URL, onPath: Bool) {
    self.url = url
    self.onPath = onPath
  }
}

public protocol ToolLocating: Sendable {
  func find(named name: String, path: String, extraDirectories: [URL]) -> ToolHit?
}

public struct SystemToolLocator: ToolLocating {
  public init() {}

  public func find(named name: String, path: String, extraDirectories: [URL]) -> ToolHit? {
    let pathHit = firstHit(name: name, directories: pathDirectories(path), onPath: true)
    let extraHit = firstHit(name: name, directories: extraDirectories, onPath: false)
    if name == "mitmdump" {
      return extraHit ?? pathHit
    }
    return pathHit ?? extraHit
  }

  private func firstHit(name: String, directories: [URL], onPath: Bool) -> ToolHit? {
    for directory in directories {
      let candidate = directory.appendingPathComponent(name)
      if isExecutable(candidate) {
        return ToolHit(url: candidate, onPath: onPath)
      }
    }
    return nil
  }

  private func pathDirectories(_ path: String) -> [URL] {
    path.split(separator: ":").compactMap { part in
      let text = String(part)
      guard !text.isEmpty else { return nil }
      return URL(fileURLWithPath: text, isDirectory: true)
    }
  }

  private func isExecutable(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    if !exists || isDirectory.boolValue {
      return false
    }
    return FileManager.default.isExecutableFile(atPath: url.path)
  }
}

public enum KnownTools {
  public static func extraDirectories(for tool: String, home: URL) -> [URL] {
    let homebrew = [
      URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
      URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
    ]
    switch tool {
    case "adb":
      return [home.appendingPathComponent("Library/Android/sdk/platform-tools")] + homebrew
    case "emulator":
      return [home.appendingPathComponent("Library/Android/sdk/emulator")] + homebrew
    case "flutter":
      return [home.appendingPathComponent("develop/flutter/bin")] + homebrew
    case "idb":
      return homebrew
    case "mitmdump":
      return [
        AppPaths.supportDirectory(home: home).appendingPathComponent(
          "mitmvenv/bin", isDirectory: true),
        URL(fileURLWithPath: "/Applications/mitmproxy.app/Contents/MacOS", isDirectory: true),
      ] + homebrew
    case "aapt", "aapt2", "zipalign", "apksigner":
      return buildToolDirectories(home: home) + homebrew
    case "curl", "xcrun", "xcodebuild", "swift":
      return [URL(fileURLWithPath: "/usr/bin", isDirectory: true)]
    default:
      return []
    }
  }

  public static func buildToolDirectories(home: URL) -> [URL] {
    let root = home.appendingPathComponent("Library/Android/sdk/build-tools", isDirectory: true)
    let urls =
      (try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )) ?? []
    return urls.filter { url in
      (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
    .sorted { $0.lastPathComponent > $1.lastPathComponent }
  }
}
