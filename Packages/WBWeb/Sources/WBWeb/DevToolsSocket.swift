import Foundation

public struct DevToolsSocket: Sendable, Equatable, Identifiable {
  public enum Kind: String, Sendable, Equatable {
    case chrome
    case webview
  }

  public var name: String
  public var kind: Kind
  public var processID: Int?

  public var id: String { name }

  public init(name: String, kind: Kind, processID: Int? = nil) {
    self.name = name
    self.kind = kind
    self.processID = processID
  }
}

public enum DevToolsSockets {
  public static func parse(_ unix: String) -> [DevToolsSocket] {
    var seen = Set<String>()
    var sockets: [DevToolsSocket] = []
    for line in unix.split(whereSeparator: \.isNewline) {
      guard let name = abstractName(in: String(line)), let socket = classify(name) else {
        continue
      }
      if seen.insert(socket.name).inserted {
        sockets.append(socket)
      }
    }
    return sockets
  }

  private static func abstractName(in line: String) -> String? {
    guard let index = line.lastIndex(of: "@") else { return nil }
    let name = String(line[line.index(after: index)...]).trimmingCharacters(
      in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name
  }

  private static func classify(_ name: String) -> DevToolsSocket? {
    if name.hasPrefix("stetho_") { return nil }
    if name == "chrome_devtools_remote" || name.hasPrefix("chrome_devtools_remote_") {
      return DevToolsSocket(name: name, kind: .chrome, processID: suffixID(name))
    }
    if name == "webview_devtools_remote" || name.hasPrefix("webview_devtools_remote_") {
      return DevToolsSocket(name: name, kind: .webview, processID: suffixID(name))
    }
    return nil
  }

  private static func suffixID(_ name: String) -> Int? {
    guard let index = name.lastIndex(of: "_") else { return nil }
    return Int(name[name.index(after: index)...])
  }
}
