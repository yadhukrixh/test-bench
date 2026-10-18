import Foundation

public struct NodeBounds: Sendable, Codable, Equatable {
  public var left: Int
  public var top: Int
  public var right: Int
  public var bottom: Int

  public init(left: Int, top: Int, right: Int, bottom: Int) {
    self.left = left
    self.top = top
    self.right = right
    self.bottom = bottom
  }

  public var width: Int { max(right - left, 0) }
  public var height: Int { max(bottom - top, 0) }
  public var area: Int { width * height }

  public func contains(x: Int, y: Int) -> Bool {
    x >= left && x < right && y >= top && y < bottom
  }

  public static func parse(_ text: String) -> NodeBounds? {
    guard
      let match = text.range(
        of: #"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]"#, options: .regularExpression)
    else { return nil }
    let body = text[match]
    let numbers = body.split { !$0.isNumber && $0 != "-" }.compactMap { Int($0) }
    guard numbers.count == 4 else { return nil }
    return NodeBounds(left: numbers[0], top: numbers[1], right: numbers[2], bottom: numbers[3])
  }
}

public struct Node: Sendable, Codable, Equatable, Identifiable {
  public var id: String
  public var className: String
  public var package: String
  public var resourceId: String
  public var text: String
  public var contentDescription: String
  public var bounds: NodeBounds
  public var clickable: Bool
  public var enabled: Bool
  public var focusable: Bool
  public var focused: Bool
  public var checkable: Bool
  public var checked: Bool
  public var selected: Bool
  public var scrollable: Bool
  public var longClickable: Bool
  public var password: Bool
  public var index: Int
  public var children: [Node]

  public init(
    id: String,
    className: String,
    package: String = "",
    resourceId: String = "",
    text: String = "",
    contentDescription: String = "",
    bounds: NodeBounds,
    clickable: Bool = false,
    enabled: Bool = true,
    focusable: Bool = false,
    focused: Bool = false,
    checkable: Bool = false,
    checked: Bool = false,
    selected: Bool = false,
    scrollable: Bool = false,
    longClickable: Bool = false,
    password: Bool = false,
    index: Int = 0,
    children: [Node] = []
  ) {
    self.id = id
    self.className = className
    self.package = package
    self.resourceId = resourceId
    self.text = text
    self.contentDescription = contentDescription
    self.bounds = bounds
    self.clickable = clickable
    self.enabled = enabled
    self.focusable = focusable
    self.focused = focused
    self.checkable = checkable
    self.checked = checked
    self.selected = selected
    self.scrollable = scrollable
    self.longClickable = longClickable
    self.password = password
    self.index = index
    self.children = children
  }

  public var label: String {
    let title = [contentDescription, text, resourceId].first { !$0.isEmpty } ?? className
    let short = className.split(separator: ".").last.map(String.init) ?? className
    if title == className || title.isEmpty {
      return short
    }
    return "\(short) · \(title)"
  }

  public func node(id: String) -> Node? {
    if self.id == id { return self }
    for child in children {
      if let found = child.node(id: id) { return found }
    }
    return nil
  }
}

public enum HitTest {
  public static func node(atX x: Int, y: Int, in root: Node) -> Node? {
    var best: Node?
    visit(root) { node in
      guard node.bounds.contains(x: x, y: y) else { return }
      if let current = best {
        if node.bounds.area < current.bounds.area
          || (node.bounds.area == current.bounds.area && node.id.count >= current.id.count)
        {
          best = node
        }
      } else {
        best = node
      }
    }
    return best
  }

  public static func clickable(
    matching names: [String], in root: Node, packages: Set<String>? = nil
  ) -> Node? {
    let rank = Dictionary(
      names.map { $0.lowercased() }.enumerated().map { ($0.element, $0.offset) },
      uniquingKeysWith: { first, _ in first }
    )
    var found: Node?
    var foundRank = Int.max
    visit(root) { node in
      guard node.clickable, node.enabled else { return }
      if let packages, !packages.contains(node.package) { return }
      let label = (node.text.isEmpty ? node.contentDescription : node.text).lowercased()
      guard let index = rank[label] else { return }
      let area = found?.bounds.area ?? Int.max
      if index < foundRank || (index == foundRank && node.bounds.area < area) {
        found = node
        foundRank = index
      }
    }
    return found
  }

  private static func visit(_ node: Node, _ body: (Node) -> Void) {
    body(node)
    for child in node.children {
      visit(child, body)
    }
  }
}

public protocol NodeSource: Sendable {
  func dump() async throws -> Node
}
