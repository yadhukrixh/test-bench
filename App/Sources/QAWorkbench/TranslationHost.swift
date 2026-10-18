import SwiftUI
import Translation
import WBVision

@MainActor
@Observable
final class TranslationBroker: Translator {
  var configuration: TranslationSession.Configuration?
  var message = ""
  fileprivate var continuation: CheckedContinuation<[String], Error>?
  fileprivate var batch: [String] = []

  func availability(from: String, to: String) async -> TranslationStatus {
    let availability = LanguageAvailability()
    let status = await availability.status(
      from: Locale.Language(identifier: from),
      to: Locale.Language(identifier: to)
    )
    switch status {
    case .installed:
      return .installed
    case .supported:
      return .supported
    default:
      return .unsupported
    }
  }

  func translate(batch: [String], from: String, to: String) async throws -> [String] {
    if let existing = continuation {
      existing.resume(throwing: CancellationError())
      continuation = nil
    }
    self.batch = batch
    return try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      configuration = TranslationSession.Configuration(
        source: Locale.Language(identifier: from),
        target: Locale.Language(identifier: to)
      )
    }
  }

  fileprivate func takeWork() -> (CheckedContinuation<[String], Error>, [String])? {
    guard let continuation else { return nil }
    self.continuation = nil
    return (continuation, batch)
  }
}

private final class SessionBox: @unchecked Sendable {
  let session: TranslationSession
  init(_ session: TranslationSession) { self.session = session }
}

struct TranslationHost: View {
  @Bindable var broker: TranslationBroker

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .translationTask(broker.configuration) { session in
        let box = SessionBox(session)
        let work = broker.takeWork()
        await Self.translate(box, work: work)
      }
  }

  nonisolated private static func translate(
    _ box: SessionBox, work: (CheckedContinuation<[String], Error>, [String])?
  ) async {
    guard let work else { return }
    do {
      var results: [String] = []
      results.reserveCapacity(work.1.count)
      for text in work.1 {
        let response = try await box.session.translate(text)
        results.append(response.targetText)
      }
      work.0.resume(returning: results)
    } catch {
      work.0.resume(throwing: error)
    }
  }
}
