import Foundation
import WBCore
import WBProcess

public enum UiAutomatorDump {
  public static let arguments = ["exec-out", "uiautomator", "dump", "/dev/tty"]

  public static func xml(from output: String) -> String {
    var text = output
    for marker in ["UI hierchary dumped to:", "UI hierarchy dumped to:"] {
      if let range = text.range(of: marker) {
        text = String(text[..<range.lowerBound])
      }
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public static func parse(_ output: String) throws -> Node {
    let xml = xml(from: output)
    guard xml.contains("<"), let data = xml.data(using: .utf8) else {
      throw WBError(
        domain: .parse,
        code: "uiautomator.empty",
        message: "The hierarchy dump was empty.",
        suggestion: "Wait until the device has a screen, then dump again."
      )
    }
    let parser = HierarchyParser()
    guard let root = parser.parse(data) else {
      throw WBError(
        domain: .parse,
        code: "uiautomator.xml",
        message: "The hierarchy dump could not be read.",
        suggestion: parser.problem
      )
    }
    return root
  }
}

public actor UiAutomatorSource: NodeSource {
  private let serial: String
  private let adb: URL
  private let runner: any CommandExecuting
  private var inFlight: Task<Node, Error>?

  public init(serial: String, adb: URL, runner: any CommandExecuting) {
    self.serial = serial
    self.adb = adb
    self.runner = runner
  }

  public func dump() async throws -> Node {
    if let inFlight {
      return try await inFlight.value
    }
    let task = Task { try await self.runDump() }
    inFlight = task
    defer { inFlight = nil }
    return try await task.value
  }

  public func dumpXML() async throws -> String {
    UiAutomatorDump.xml(from: try await rawDump())
  }

  private func runDump() async throws -> Node {
    try UiAutomatorDump.parse(try await rawDump())
  }

  private func rawDump() async throws -> String {
    var arguments = ["-s", serial]
    arguments.append(contentsOf: UiAutomatorDump.arguments)
    let result = try await runner.execute(
      executable: adb,
      arguments: arguments,
      timeout: .seconds(20),
      environment: nil
    )
    let output = result.stdoutText + result.stderrText
    guard result.status == 0 || output.contains("<hierarchy") || output.contains("<node") else {
      throw WBError(
        domain: .source,
        code: "uiautomator.dump",
        message: "The emulator did not return a hierarchy.",
        suggestion: output,
        retryable: true
      )
    }
    return output
  }
}

public struct UnavailableIOSNodes: NodeSource {
  public init() {}

  public func dump() async throws -> Node {
    throw WBError(
      domain: .environment,
      code: "idb.missing",
      message: "idb is not installed, so the simulator has no hierarchy.",
      suggestion: "The tree is available on a booted Android emulator."
    )
  }
}

private final class HierarchyParser: NSObject, XMLParserDelegate {
  var problem: String?
  private var stack: [Node] = []
  private var root: Node?
  private var nextChild = [0]

  func parse(_ data: Data) -> Node? {
    let parser = XMLParser(data: data)
    parser.delegate = self
    parser.shouldProcessNamespaces = false
    guard parser.parse() else {
      problem = parser.parserError?.localizedDescription ?? "The XML ended early."
      return nil
    }
    return root
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName: String?,
    attributes: [String: String] = [:]
  ) {
    guard elementName == "node" else { return }
    let index = nextChild.last ?? 0
    if !nextChild.isEmpty {
      nextChild[nextChild.count - 1] += 1
    }
    nextChild.append(0)
    let parentID = stack.last?.id ?? ""
    let id = parentID.isEmpty ? String(index) : "\(parentID)/\(index)"
    let bounds =
      NodeBounds.parse(attributes["bounds"] ?? "")
      ?? NodeBounds(left: 0, top: 0, right: 0, bottom: 0)
    let node = Node(
      id: id,
      className: attributes["class"] ?? "",
      package: attributes["package"] ?? "",
      resourceId: attributes["resource-id"] ?? "",
      text: attributes["text"] ?? "",
      contentDescription: attributes["content-desc"] ?? "",
      bounds: bounds,
      clickable: attributes["clickable"] == "true",
      enabled: attributes["enabled"] != "false",
      focusable: attributes["focusable"] == "true",
      focused: attributes["focused"] == "true",
      checkable: attributes["checkable"] == "true",
      checked: attributes["checked"] == "true",
      selected: attributes["selected"] == "true",
      scrollable: attributes["scrollable"] == "true",
      longClickable: attributes["long-clickable"] == "true",
      password: attributes["password"] == "true",
      index: Int(attributes["index"] ?? "") ?? index,
      children: []
    )
    stack.append(node)
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName: String?
  ) {
    guard elementName == "node" else { return }
    guard let finished = stack.popLast() else { return }
    if !nextChild.isEmpty {
      nextChild.removeLast()
    }
    if var parent = stack.popLast() {
      parent.children.append(finished)
      stack.append(parent)
    } else {
      root = finished
    }
  }
}
