import Darwin
import Foundation

public enum OrphanReaper {
  public static func reap(directory: URL) -> [Int32] {
    let manager = FileManager.default
    guard
      let urls = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    else {
      return []
    }
    var killed: [Int32] = []
    for url in urls where url.pathExtension == "json" {
      guard let data = try? Data(contentsOf: url),
        let record = try? JSONDecoder().decode(PidRecord.self, from: data)
      else {
        continue
      }
      guard TrackedKind.all.contains(record.kind) else {
        continue
      }
      if parentStillRunning(record.pid) {
        continue
      }
      guard let command = commandLine(pid: record.pid),
        commandMatches(command, record: record)
      else {
        try? manager.removeItem(at: url)
        continue
      }
      Darwin.kill(record.pid, SIGTERM)
      let deadline = Date().addingTimeInterval(2)
      while Date() < deadline && Darwin.kill(record.pid, 0) == 0 {
        usleep(50_000)
      }
      if Darwin.kill(record.pid, 0) == 0 {
        Darwin.kill(record.pid, SIGKILL)
      }
      killed.append(record.pid)
      try? manager.removeItem(at: url)
    }
    return killed
  }

  static func commandMatches(_ command: String, record: PidRecord) -> Bool {
    if command.contains(record.executable) {
      return true
    }
    let name = URL(fileURLWithPath: record.executable).lastPathComponent
    let tokens = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    if tokens.contains(name) {
      return true
    }
    if record.kind == TrackedKind.emulator,
      command.contains("qemu-system"),
      let avd = flagValue("-avd", in: record.arguments),
      command.contains(avd)
    {
      return true
    }
    return false
  }

  private static func flagValue(_ flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag) else { return nil }
    let next = arguments.index(after: index)
    guard next < arguments.endIndex else { return nil }
    return arguments[next]
  }

  private static func parentStillRunning(_ pid: Int32) -> Bool {
    guard let parent = parentPid(pid), parent > 1 else { return false }
    return Darwin.kill(parent, 0) == 0
  }

  private static func parentPid(_ pid: Int32) -> Int32? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-p", String(pid), "-o", "ppid="]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return nil
    }
    process.waitUntilExit()
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return Int32(text)
  }

  private static func commandLine(pid: Int32) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-p", String(pid), "-o", "command="]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return nil
    }
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let text = String(decoding: data, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }
}
