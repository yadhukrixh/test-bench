import Foundation

public enum SessionState: String, Sendable, Codable, Equatable {
  case idle
  case booting
  case ready
  case stopping
  case failed
}
