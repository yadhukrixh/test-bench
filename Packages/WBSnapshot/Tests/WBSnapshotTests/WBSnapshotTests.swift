import CoreGraphics
import Foundation
import Testing

@testable import WBSnapshot

struct SnapshotStoreTests {
  @Test func writesPNGAndXMLThenListsThem() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    guard let image = pixelImage(), let png = SnapshotImage.png(from: image) else {
      Issue.record("Could not encode a PNG.")
      return
    }
    #expect(png.starts(with: Data([0x89, 0x50, 0x4E, 0x47])))
    let store = SnapshotStore(directory: root)
    let xml = "<hierarchy><node text=\"OK\"/></hierarchy>"
    let saved = try await store.save(
      SnapshotCapture(png: png, xml: xml), createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    #expect(FileManager.default.fileExists(atPath: saved.pngURL.path))
    #expect(try String(contentsOf: saved.xmlURL, encoding: .utf8) == xml)
    let listed = try await store.list()
    #expect(listed.count == 1)
    #expect(listed[0].id == saved.id)
  }
}

private func pixelImage() -> CGImage? {
  var pixel: [UInt8] = [255, 0, 0, 255]
  return pixel.withUnsafeMutableBytes { buffer in
    guard let base = buffer.baseAddress else { return nil }
    let context = CGContext(
      data: base,
      width: 1,
      height: 1,
      bitsPerComponent: 8,
      bytesPerRow: 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
    return context?.makeImage()
  }
}
