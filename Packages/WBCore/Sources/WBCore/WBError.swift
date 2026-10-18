import Foundation

public struct WBError: Error, Sendable, Equatable {
  public enum Domain: String, Sendable, Codable {
    case environment
    case device
    case source
    case parse
    case resource
    case user
  }

  public var domain: Domain
  public var code: String
  public var message: String
  public var suggestion: String?
  public var underlying: String?
  public var retryable: Bool

  public init(
    domain: Domain,
    code: String,
    message: String,
    suggestion: String? = nil,
    underlying: String? = nil,
    retryable: Bool = false
  ) {
    self.domain = domain
    self.code = code
    self.message = message
    self.suggestion = suggestion
    self.underlying = underlying
    self.retryable = retryable
  }
}

extension WBError: LocalizedError {
  public var errorDescription: String? { message }
  public var recoverySuggestion: String? { suggestion }
}

extension WBError {
  public static func wrap(_ error: Error, domain: Domain, code: String, message: String) -> WBError
  {
    if let existing = error as? WBError {
      return existing
    }
    return WBError(
      domain: domain,
      code: code,
      message: message,
      underlying: String(describing: error)
    )
  }
}
