import Foundation

public struct DevicePackage: Sendable, Equatable, Identifiable {
  public var path: String
  public var id: String { path }

  public init(path: String) {
    self.path = path
  }

  public var name: String {
    URL(fileURLWithPath: path).lastPathComponent
  }
}

public enum DeviceStorage {
  public static let folders = [
    "/sdcard/Download",
    "/sdcard/Downloads",
    "/sdcard",
    "/data/local/tmp",
    "/storage/emulated/0/Download",
    "/storage/emulated/0/Downloads",
  ]

  public static func isAPKPath(_ path: String) -> Bool {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("/"),
      !trimmed.contains(".."),
      !trimmed.contains("\n"),
      !trimmed.contains("\0"),
      trimmed.lowercased().hasSuffix(".apk")
    else { return false }
    return folders.contains { folder in
      trimmed == folder || trimmed.hasPrefix(folder + "/")
    }
  }

  public static func paths(fromListing text: String, folder: String) -> [String] {
    var found: [String] = []
    for line in text.split(whereSeparator: \.isNewline) {
      let name = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty, !name.hasPrefix("ls:") else { continue }
      let path = name.hasPrefix("/") ? name : "\(folder)/\(name)"
      if isAPKPath(path), !found.contains(path) {
        found.append(path)
      }
    }
    return found
  }
}
