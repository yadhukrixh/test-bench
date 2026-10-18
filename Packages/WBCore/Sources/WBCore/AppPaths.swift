import Foundation

public enum AppPaths {
  public static func supportDirectory(
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    home.appendingPathComponent("Library/Application Support/QA Workbench", isDirectory: true)
  }

  public static func ensure(
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) throws -> URL {
    let root = supportDirectory(home: home)
    let manager = FileManager.default
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    try manager.createDirectory(
      at: root.appendingPathComponent("pids", isDirectory: true),
      withIntermediateDirectories: true
    )
    try manager.createDirectory(
      at: root.appendingPathComponent("logs", isDirectory: true),
      withIntermediateDirectories: true
    )
    return root
  }
}
