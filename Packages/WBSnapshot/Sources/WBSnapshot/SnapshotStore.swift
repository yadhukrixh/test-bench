import Foundation

public struct SnapshotCapture: Sendable, Equatable {
  public var png: Data
  public var xml: String

  public init(png: Data, xml: String) {
    self.png = png
    self.xml = xml
  }
}

public struct SnapshotRecord: Sendable, Equatable, Identifiable {
  public var id: String
  public var createdAt: Date
  public var pngURL: URL
  public var xmlURL: URL

  public init(id: String, createdAt: Date, pngURL: URL, xmlURL: URL) {
    self.id = id
    self.createdAt = createdAt
    self.pngURL = pngURL
    self.xmlURL = xmlURL
  }
}

public actor SnapshotStore {
  private let directory: URL

  public init(directory: URL) {
    self.directory = directory
  }

  public func save(_ capture: SnapshotCapture, createdAt: Date = Date()) throws -> SnapshotRecord {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let id = Self.makeID(createdAt)
    let pngURL = directory.appendingPathComponent("\(id).png")
    let xmlURL = directory.appendingPathComponent("\(id).xml")
    try capture.png.write(to: pngURL, options: .atomic)
    try Data(capture.xml.utf8).write(to: xmlURL, options: .atomic)
    return SnapshotRecord(id: id, createdAt: createdAt, pngURL: pngURL, xmlURL: xmlURL)
  }

  public func list() throws -> [SnapshotRecord] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    let files = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.creationDateKey],
      options: [.skipsHiddenFiles]
    )
    return files.compactMap { png -> SnapshotRecord? in
      guard png.pathExtension.lowercased() == "png" else { return nil }
      let id = png.deletingPathExtension().lastPathComponent
      let xmlURL = directory.appendingPathComponent("\(id).xml")
      guard FileManager.default.fileExists(atPath: xmlURL.path) else { return nil }
      let created =
        (try? png.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
      return SnapshotRecord(id: id, createdAt: created, pngURL: png, xmlURL: xmlURL)
    }.sorted { $0.createdAt > $1.createdAt }
  }

  private static func makeID(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return "\(formatter.string(from: date))-\(UUID().uuidString.prefix(8))"
  }
}
