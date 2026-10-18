import Darwin
import Foundation

public struct EmulatorEndpoint: Sendable, Equatable {
  public var pid: Int32
  public var avdID: String
  public var serialPort: Int
  public var grpcPort: Int?

  public init(pid: Int32, avdID: String, serialPort: Int, grpcPort: Int?) {
    self.pid = pid
    self.avdID = avdID
    self.serialPort = serialPort
    self.grpcPort = grpcPort
  }
}

public enum EmulatorDiscovery {
  public static func directory(home: URL) -> URL {
    home.appendingPathComponent("Library/Caches/TemporaryItems/avd/running")
  }

  public static func parse(text: String, pid: Int32) -> EmulatorEndpoint? {
    var values: [String: String] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
      let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
      if parts.count == 2 {
        values[parts[0]] = parts[1]
      }
    }
    guard let avd = values["avd.id"] ?? values["avd.name"], !avd.isEmpty else {
      return nil
    }
    guard let serial = values["port.serial"].flatMap(Int.init) else {
      return nil
    }
    return EmulatorEndpoint(
      pid: pid,
      avdID: avd,
      serialPort: serial,
      grpcPort: values["grpc.port"].flatMap(Int.init)
    )
  }

  public static func read(home: URL) -> [EmulatorEndpoint] {
    let folder = directory(home: home)
    guard
      let urls = try? FileManager.default.contentsOfDirectory(
        at: folder,
        includingPropertiesForKeys: nil
      )
    else {
      return []
    }
    var endpoints: [EmulatorEndpoint] = []
    for url in urls where url.lastPathComponent.hasPrefix("pid_") && url.pathExtension == "ini" {
      let pidText = url.deletingPathExtension().lastPathComponent.dropFirst("pid_".count)
      guard let pid = Int32(pidText) else { continue }
      if kill(pid, 0) != 0 {
        try? FileManager.default.removeItem(at: url)
        continue
      }
      guard let text = try? String(contentsOf: url, encoding: .utf8),
        let endpoint = parse(text: text, pid: pid)
      else {
        continue
      }
      endpoints.append(endpoint)
    }
    return endpoints
  }
}
