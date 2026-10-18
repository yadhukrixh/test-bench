import CoreGraphics
import Foundation
import Testing
import WBInspect

@testable import WBVision

struct TextLayerTests {
  @Test func convertsVisionBoxesToDevicePixels() {
    let bounds = TextGeometry.deviceBounds(
      normalized: CGRect(x: 0.1, y: 0.25, width: 0.2, height: 0.1),
      width: 1000,
      height: 2000
    )
    #expect(bounds.left == 100)
    #expect(bounds.right == 300)
    #expect(bounds.top == 1300)
    #expect(bounds.bottom == 1500)
  }

  @Test func dropsOCRWhenItOverlapsNodeText() {
    let node = TextRun(
      id: "node:0",
      text: "ログインして続行",
      bounds: NodeBounds(left: 10, top: 10, right: 200, bottom: 80),
      origin: .node
    )
    let ocr = TextRun(
      id: "ocr:0",
      text: "ログインして続行",
      bounds: NodeBounds(left: 12, top: 12, right: 198, bottom: 78),
      origin: .ocr,
      confidence: 1
    )
    let extra = TextRun(
      id: "ocr:1",
      text: "Hello from OCR",
      bounds: NodeBounds(left: 10, top: 200, right: 300, bottom: 240),
      origin: .ocr
    )
    let merged = TextLayer.merge(nodes: [node], ocr: [ocr, extra])
    #expect(merged.contains { $0.id == "node:0" })
    #expect(!merged.contains { $0.id == "ocr:0" })
    #expect(merged.contains { $0.id == "ocr:1" })
    #expect(TextGeometry.iou(node.bounds, ocr.bounds) >= TextGeometry.overlap)
  }

  @Test func readsNodeTextAndHitsTheSmallerRun() {
    let inner = Node(
      id: "0/1",
      className: "android.widget.TextView",
      text: "",
      contentDescription: "ログイン",
      bounds: NodeBounds(left: 100, top: 100, right: 200, bottom: 140)
    )
    let root = Node(
      id: "0",
      className: "android.widget.FrameLayout",
      bounds: NodeBounds(left: 0, top: 0, right: 1080, bottom: 2400),
      children: [inner]
    )
    let runs = TextLayer.runs(from: root)
    #expect(runs.contains { $0.text == "ログイン" && $0.origin == .node })
    #expect(TextGeometry.hit(x: 150, y: 120, in: runs)?.text == "ログイン")
  }

  @Test func cacheStoresTranslations() async {
    let cache = TranslationCache()
    let key = TranslationCache.key(text: "hello", from: "en", to: "ja")
    await cache.store(key, "こんにちは")
    #expect(await cache.value(for: key) == "こんにちは")
    #expect(!LanguageDetect.isAlready("ログインして続行", language: "en"))
  }
}
