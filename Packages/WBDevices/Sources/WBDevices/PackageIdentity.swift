import Foundation

public enum PackageIdentity {
  public static func name(fromBadging text: String) -> String? {
    if let name = quotedValue(in: text, key: "package: name=") {
      return name
    }
    let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if line.contains("."), !line.contains(" "), !line.contains("\n") {
      return line
    }
    return nil
  }

  public static func activity(fromBadging text: String) -> String? {
    quotedValue(in: text, key: "launchable-activity: name=")
  }

  public static func startArguments(serial: String, package: String, activity: String) -> [String] {
    ["-s", serial, "shell", "am", "start", "-n", "\(package)/\(activity)"]
  }

  public static func launchArguments(serial: String, package: String) -> [String] {
    [
      "-s", serial, "shell", "monkey", "-p", package, "-c", "android.intent.category.LAUNCHER", "1",
    ]
  }

  public static func badgingArguments(apk: URL) -> [String] {
    ["dump", "badging", apk.path]
  }

  public static func startedSuccessfully(_ text: String) -> Bool {
    let lower = text.lowercased()
    if lower.contains("error type") || lower.contains("does not exist")
      || lower.contains("unable to resolve")
    {
      return false
    }
    return text.contains("Starting: Intent") || text.contains("Events injected")
      || text.contains("Warning: Activity not started")
  }

  private static func quotedValue(in text: String, key: String) -> String? {
    guard let range = text.range(of: key) else { return nil }
    let rest = text[range.upperBound...]
    guard rest.first == "'" else { return nil }
    let after = rest.dropFirst()
    guard let end = after.firstIndex(of: "'") else { return nil }
    let value = String(after[..<end])
    return value.isEmpty ? nil : value
  }
}
