import Foundation
import WBCore

public enum PackageFile {
  public static let maximumDownloadBytes = 200 * 1024 * 1024

  public static let apkSearchMaxDepth = 8
  public static let apkSearchLimit = 8

  public static func isAPK(_ file: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
    defer { try? handle.close() }
    let magic = (try? handle.read(upToCount: 4)) ?? Data()
    return magic == Data([0x50, 0x4B, 0x03, 0x04])
  }

  public static func downloadsDirectory() -> URL? {
    FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
  }

  public static func apks(in item: URL) -> [URL] {
    var found: [URL] = []
    collectAPKs(from: item, depth: 0, into: &found)
    return found.sorted { $0.path < $1.path }
  }

  public static func topLevelAPKs(in directory: URL) -> [URL] {
    (try? listTopLevelAPKs(in: directory)) ?? []
  }

  public static func listTopLevelAPKs(in directory: URL) throws -> [URL] {
    let children = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
    return children.filter { child in
      child.pathExtension.lowercased() == "apk"
        && (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
    }.sorted {
      $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
    }
  }

  public static func resolveAPKs(from items: [URL]) -> [URL] {
    var seen = Set<String>()
    var found: [URL] = []
    for item in items {
      for apk in resolveAPKs(from: item) {
        let path = apk.standardizedFileURL.path
        if seen.insert(path).inserted {
          found.append(apk)
        }
      }
    }
    return found
  }

  public static func resolveAPKs(from item: URL) -> [URL] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory) else {
      return []
    }
    if !isDirectory.boolValue {
      if item.pathExtension.lowercased() == "apk" || isAPK(item) {
        return [item]
      }
      return []
    }
    let top = topLevelAPKs(in: item)
    if !top.isEmpty {
      return top
    }
    return apks(in: item)
  }

  private static let skippedDirectoryNames: Set<String> = [
    ".dart_tool",
    ".git",
    ".gradle",
    ".hg",
    ".idea",
    ".svn",
    "DerivedData",
    "Pods",
    "__pycache__",
    "node_modules",
    "xcuserdata",
  ]

  private static func collectAPKs(from item: URL, depth: Int, into found: inout [URL]) {
    guard found.count < apkSearchLimit else { return }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory) else {
      return
    }
    if !isDirectory.boolValue {
      if isAPK(item) {
        found.append(item)
      }
      return
    }
    guard depth <= apkSearchMaxDepth else { return }
    if depth > 0, skippedDirectoryNames.contains(item.lastPathComponent) {
      return
    }
    guard
      let children = try? FileManager.default.contentsOfDirectory(
        at: item,
        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else { return }
    for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      if child.hasDirectoryPath
        || (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      {
        collectAPKs(from: child, depth: depth + 1, into: &found)
      } else if child.pathExtension.lowercased() == "apk" {
        collectAPKs(from: child, depth: depth + 1, into: &found)
      }
      if found.count >= apkSearchLimit { return }
    }
  }

  public static func installArguments(serial: String, apk: URL) -> [String] {
    ["-s", serial, "install", "-r", "-t", "-d", apk.path]
  }

  public static func replacesInstalledPackage(_ output: String) -> Bool {
    output.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE")
  }

  public static func pullArguments(serial: String, remote: String, destination: URL) -> [String] {
    ["-s", serial, "pull", remote, destination.path]
  }

  public static func acceptedDownloadURL(_ text: String) -> URL? {
    var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count >= 2,
      (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
        || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'"))
    {
      trimmed = String(trimmed.dropFirst().dropLast())
    }
    guard let url = URL(string: trimmed),
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = url.host,
      !host.isEmpty
    else { return nil }
    return url
  }

  public static func downloadArguments(url: URL, destination: URL) -> [String] {
    [
      "-L",
      "--fail",
      "--max-filesize", String(maximumDownloadBytes),
      "--connect-timeout", "30",
      "-o", destination.path,
      url.absoluteString,
    ]
  }

  public static func download(from url: URL, to destination: URL) async throws {
    guard acceptedDownloadURL(url.absoluteString) != nil else {
      throw WBError(
        domain: .user,
        code: "apk.url",
        message: "Enter an http or https address for the APK."
      )
    }
    let transfer = APKTransfer(limit: maximumDownloadBytes, destination: destination)
    try await transfer.run(url)
  }
}

private final class APKTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private let limit: Int
  private let destination: URL
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Error>?
  private var tooBig = false
  private var copyError: Error?
  private var resumed = false

  init(limit: Int, destination: URL) {
    self.limit = limit
    self.destination = destination
  }

  func run(_ url: URL) async throws {
    let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    var request = URLRequest(url: url)
    request.timeoutInterval = 180
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      self.store(continuation)
      session.downloadTask(with: request).resume()
    }
  }

  private func store(_ continuation: CheckedContinuation<Void, Error>) {
    lock.lock()
    self.continuation = continuation
    lock.unlock()
  }

  private func finish(_ result: Result<Void, Error>) {
    lock.lock()
    guard !resumed, let continuation else {
      lock.unlock()
      return
    }
    resumed = true
    self.continuation = nil
    lock.unlock()
    switch result {
    case .success:
      continuation.resume()
    case .failure(let error):
      continuation.resume(throwing: error)
    }
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    if totalBytesWritten > Int64(limit) || totalBytesExpectedToWrite > Int64(limit) {
      tooBig = true
      downloadTask.cancel()
    }
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    let size = (try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    if size > limit {
      tooBig = true
      return
    }
    do {
      let folder = destination.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.copyItem(at: location, to: destination)
    } catch {
      copyError = error
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if tooBig {
      try? FileManager.default.removeItem(at: destination)
      finish(
        .failure(
          WBError(
            domain: .resource, code: "apk.size", message: "That APK is larger than 200 MB.")))
      return
    }
    if let copyError {
      try? FileManager.default.removeItem(at: destination)
      finish(.failure(copyError))
      return
    }
    if let error {
      try? FileManager.default.removeItem(at: destination)
      finish(
        .failure(
          WBError.wrap(
            error, domain: .resource, code: "apk.download", message: "The APK download failed.")
        ))
      return
    }
    if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      try? FileManager.default.removeItem(at: destination)
      finish(
        .failure(
          WBError(
            domain: .resource,
            code: "apk.http",
            message: "The download returned HTTP \(http.statusCode).",
            retryable: true
          )))
      return
    }
    finish(.success(()))
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    guard let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https"
    else {
      return nil
    }
    return request
  }
}
