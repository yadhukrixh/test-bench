import CoreGraphics
import Foundation
import WBInspect

public enum TextOrigin: String, Sendable, Codable, Equatable {
  case node
  case ocr
}

public struct TextRun: Sendable, Codable, Equatable, Identifiable {
  public var id: String
  public var text: String
  public var bounds: NodeBounds
  public var origin: TextOrigin
  public var confidence: Float
  public var translation: String?

  public init(
    id: String,
    text: String,
    bounds: NodeBounds,
    origin: TextOrigin,
    confidence: Float = 1,
    translation: String? = nil
  ) {
    self.id = id
    self.text = text
    self.bounds = bounds
    self.origin = origin
    self.confidence = confidence
    self.translation = translation
  }

  public var label: String {
    if let translation, !translation.isEmpty {
      return translation
    }
    return text
  }
}

public enum TextGeometry {
  public static let overlap: Double = 0.5

  public static func deviceBounds(normalized: CGRect, width: Int, height: Int) -> NodeBounds {
    let w = Double(max(width, 1))
    let h = Double(max(height, 1))
    let left = Int((normalized.minX * w).rounded())
    let right = Int((normalized.maxX * w).rounded())
    let top = Int(((1 - normalized.maxY) * h).rounded())
    let bottom = Int(((1 - normalized.minY) * h).rounded())
    return NodeBounds(left: left, top: top, right: right, bottom: bottom)
  }

  public static func iou(_ a: NodeBounds, _ b: NodeBounds) -> Double {
    let left = max(a.left, b.left)
    let top = max(a.top, b.top)
    let right = min(a.right, b.right)
    let bottom = min(a.bottom, b.bottom)
    let width = max(right - left, 0)
    let height = max(bottom - top, 0)
    let intersection = Double(width * height)
    let union = Double(a.area + b.area) - intersection
    guard union > 0 else { return 0 }
    return intersection / union
  }

  public static func similar(_ a: String, _ b: String) -> Bool {
    let left = normalize(a)
    let right = normalize(b)
    if left.isEmpty || right.isEmpty { return false }
    return left == right || left.contains(right) || right.contains(left)
  }

  public static func hit(x: Int, y: Int, in runs: [TextRun]) -> TextRun? {
    var best: TextRun?
    for run in runs where run.bounds.contains(x: x, y: y) {
      if let current = best {
        if run.bounds.area < current.bounds.area { best = run }
      } else {
        best = run
      }
    }
    return best
  }

  private static func normalize(_ text: String) -> String {
    text.lowercased().filter { !$0.isWhitespace }
  }
}

public enum TextLayer {
  public static func runs(from node: Node) -> [TextRun] {
    var found: [TextRun] = []
    visit(node, path: node.id, into: &found)
    return found
  }

  public static func merge(nodes: [TextRun], ocr: [TextRun]) -> [TextRun] {
    var kept: [TextRun] = nodes.filter {
      !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    for line in ocr {
      let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { continue }
      let duplicate = kept.contains { node in
        TextGeometry.iou(node.bounds, line.bounds) >= TextGeometry.overlap
          && TextGeometry.similar(node.text, line.text)
      }
      if !duplicate {
        kept.append(line)
      }
    }
    return kept.sorted { lhs, rhs in
      if lhs.bounds.top == rhs.bounds.top {
        return lhs.bounds.left < rhs.bounds.left
      }
      return lhs.bounds.top < rhs.bounds.top
    }
  }

  private static func visit(_ node: Node, path: String, into runs: inout [TextRun]) {
    let text = [node.text, node.contentDescription].first {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    if let text, node.bounds.width > 0, node.bounds.height > 0 {
      runs.append(
        TextRun(id: "node:\(path)", text: text, bounds: node.bounds, origin: .node, confidence: 1)
      )
    }
    for (index, child) in node.children.enumerated() {
      visit(child, path: "\(path)/\(index)", into: &runs)
    }
  }
}
