import Foundation
import NaturalLanguage

public enum TranslationStatus: String, Sendable, Equatable {
  case installed
  case supported
  case unsupported
}

public protocol Translator: Sendable {
  func availability(from: String, to: String) async -> TranslationStatus
  func translate(batch: [String], from: String, to: String) async throws -> [String]
}

public actor TranslationCache {
  public static let limit = 5_000
  private var map: [String: String] = [:]
  private var order: [String] = []

  public init() {}

  public static func key(text: String, from: String, to: String) -> String {
    "\(from)|\(to)|\(text)"
  }

  public func value(for key: String) -> String? {
    map[key]
  }

  public func store(_ key: String, _ value: String) {
    if map[key] == nil {
      order.append(key)
    }
    map[key] = value
    while order.count > Self.limit {
      let old = order.removeFirst()
      map[old] = nil
    }
  }
}

public enum LanguageDetect {
  public static func code(for text: String) -> String? {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    guard let language = recognizer.dominantLanguage else { return nil }
    return language.rawValue
  }

  public static func isAlready(_ text: String, language: String) -> Bool {
    guard let detected = code(for: text) else { return false }
    return detected == language || detected.hasPrefix(language + "-")
      || language.hasPrefix(detected)
  }
}
