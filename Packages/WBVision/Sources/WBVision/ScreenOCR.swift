import CoreGraphics
import Foundation
import Vision

public enum ScreenOCR {
  public static let wantedLanguages = ["ja-JP", "en-US"]

  public static func supportedLanguages() throws -> [String] {
    let request = VNRecognizeTextRequest()
    return try request.supportedRecognitionLanguages()
  }

  public static func recognize(_ image: CGImage, deviceWidth: Int, deviceHeight: Int) throws
    -> [TextRun]
  {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    let supported = try request.supportedRecognitionLanguages()
    let wanted = wantedLanguages.filter { supported.contains($0) }
    request.recognitionLanguages = wanted.isEmpty ? supported : wanted
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try handler.perform([request])
    let observations = request.results ?? []
    return observations.enumerated().compactMap { index, observation in
      guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else {
        return nil
      }
      return TextRun(
        id: "ocr:\(index)",
        text: candidate.string,
        bounds: TextGeometry.deviceBounds(
          normalized: observation.boundingBox, width: deviceWidth, height: deviceHeight),
        origin: .ocr,
        confidence: candidate.confidence
      )
    }
  }
}
