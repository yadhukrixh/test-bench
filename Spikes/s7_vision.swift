import AppKit
import Foundation
import Translation
import Vision

/// Phase 0 spike S7. Renders a 1080x2400 fixture, OCRs it, and tries the
/// UI-less TranslationSession initializer. Prints one JSON object.

let japanese = "ログインして続行してください。これは品質確認のための文章です。"
let english = "The quick brown fox jumps over the lazy dog."

func renderFixture() -> CGImage {
    let width = 1080
    let height = 2400
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .left
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 48),
        .foregroundColor: NSColor.black,
        .paragraphStyle: paragraph,
    ]
    // AppKit origin is bottom-left. Place both paragraphs in the upper half.
    (english as NSString).draw(
        in: NSRect(x: 64, y: 1900, width: 952, height: 280),
        withAttributes: attrs
    )
    (japanese as NSString).draw(
        in: NSRect(x: 64, y: 1500, width: 952, height: 320),
        withAttributes: attrs
    )
    image.unlockFocus()
    var proposed = NSRect(x: 0, y: 0, width: width, height: height)
    guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
        fatalError("cgImage failed")
    }
    return cg
}

func ocr(_ image: CGImage) async throws -> [String: Any] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    let supported = try request.supportedRecognitionLanguages()
    let wanted = ["ja-JP", "en-US"].filter { supported.contains($0) }
    request.recognitionLanguages = wanted.isEmpty ? supported : wanted

    let started = CFAbsoluteTimeGetCurrent()
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try handler.perform([request])
    let elapsed = CFAbsoluteTimeGetCurrent() - started
    let observations = request.results ?? []
    let lines: [[String: Any]] = observations.map { observation in
        let box = observation.boundingBox
        return [
            "text": observation.topCandidates(1).first?.string ?? "",
            "confidence": observation.topCandidates(1).first?.confidence ?? 0,
            "box": [box.origin.x, box.origin.y, box.size.width, box.size.height],
        ]
    }
    return [
        "supportedLanguages": supported,
        "requestedLanguages": request.recognitionLanguages,
        "japaneseSupported": supported.contains("ja-JP"),
        "elapsedMs": Int(elapsed * 1000),
        "image": ["w": image.width, "h": image.height],
        "lines": lines,
    ]
}

func translateProbe() async -> [String: Any] {
    let availability = LanguageAvailability()
    let japanese = Locale.Language(identifier: "ja")
    let english = Locale.Language(identifier: "en")
    let jaToEn = await availability.status(from: japanese, to: english)
    let enToJa = await availability.status(from: english, to: japanese)
    var report: [String: Any] = [
        "jaToEn": String(describing: jaToEn),
        "enToJa": String(describing: enToJa),
        "uiLessInitializer": "TranslationSession(installedSource:target:)",
    ]
    do {
        let started = CFAbsoluteTimeGetCurrent()
        let session = TranslationSession(installedSource: japanese, target: english)
        let response = try await session.translate(japaneseText)
        report["translated"] = response.targetText
        report["elapsedMs"] = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
        report["ok"] = true
    } catch {
        report["ok"] = false
        report["error"] = String(describing: error)
    }
    return report
}

let japaneseText = japanese

@main
struct SpikeMain {
    static func main() async {
        let image = renderFixture()
        var payload: [String: Any] = [:]
        do {
            payload["ocr"] = try await ocr(image)
        } catch {
            payload["ocr"] = ["error": String(describing: error)]
        }
        payload["translation"] = await translateProbe()
        let data = try! JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
