import Foundation

public enum AndroidSDK {
  public static func discover(environment: [String: String], home: URL) -> URL? {
    for key in ["ANDROID_SDK_ROOT", "ANDROID_HOME"] {
      if let raw = environment[key], !raw.isEmpty {
        let url = URL(fileURLWithPath: raw)
        if directoryExists(url) {
          return url
        }
      }
    }
    let fallback = home.appendingPathComponent("Library/Android/sdk")
    if directoryExists(fallback) {
      return fallback
    }
    return nil
  }

  private static func directoryExists(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }
}

public enum ADBText {
  public static func emulatorSerials(in text: String) -> [String] {
    text.split(whereSeparator: \.isNewline).compactMap { line in
      let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
      guard parts.count >= 2, parts[0].hasPrefix("emulator-"), parts[1] == "device" else {
        return nil
      }
      return parts[0]
    }
  }

  public static func consolePort(serial: String) -> Int? {
    guard serial.hasPrefix("emulator-") else { return nil }
    return Int(serial.dropFirst("emulator-".count))
  }

  public static func foregroundPackage(in text: String) -> String? {
    for line in text.split(whereSeparator: \.isNewline).map(String.init) {
      guard line.contains("mCurrentFocus=") || line.contains("mFocusedApp=") else { continue }
      guard let user = line.range(of: " u0 ") else { continue }
      let rest = line[user.upperBound...]
      guard let slash = rest.firstIndex(of: "/") else { continue }
      let name = String(rest[..<slash]).trimmingCharacters(in: .whitespaces)
      if !name.isEmpty { return name }
    }
    return nil
  }

  public static func packageAPKPaths(in text: String) -> [String] {
    text.split(whereSeparator: \.isNewline).compactMap { line in
      let raw = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
      guard raw.hasPrefix("package:") else { return nil }
      let path = String(raw.dropFirst("package:".count))
      return path.isEmpty ? nil : path
    }
  }
}

public enum EmulatorLaunch {
  /// Console ports the emulator accepts are the even numbers from 5554 through 5584.
  public static let minimumConsolePort = 5554
  public static let maximumConsolePort = 5584

  public static func grpcPort(forConsole port: Int) -> Int {
    port + 3000
  }

  public static func chooseConsolePort(used: Set<Int>) -> Int? {
    var port = minimumConsolePort
    while port <= maximumConsolePort {
      if !used.contains(port) {
        return port
      }
      port += 2
    }
    return nil
  }

  public static func arguments(avd: String, consolePort: Int, grpcPort: Int) -> [String] {
    [
      "-avd", avd,
      "-port", String(consolePort),
      "-grpc", String(grpcPort),
      "-no-window",
      "-no-audio",
      "-no-boot-anim",
      "-crash-report-mode", "disabled",
    ]
  }
}
