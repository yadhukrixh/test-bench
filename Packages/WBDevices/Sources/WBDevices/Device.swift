import Foundation
import WBCore

public enum DevicePlatform: String, Codable, Sendable, Equatable {
  case android
  case ios
}

public enum DeviceState: String, Codable, Sendable, Equatable {
  case shutdown
  case booting
  case booted
}

public struct Device: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var platform: DevicePlatform
  public var name: String
  public var state: DeviceState
  public var serial: String?
  public var grpcPort: Int?
  public var detail: String

  public init(
    id: String,
    platform: DevicePlatform,
    name: String,
    state: DeviceState,
    serial: String? = nil,
    grpcPort: Int? = nil,
    detail: String
  ) {
    self.id = id
    self.platform = platform
    self.name = name
    self.state = state
    self.serial = serial
    self.grpcPort = grpcPort
    self.detail = detail
  }
}

public struct DeviceInventory: Sendable, Equatable {
  public var devices: [Device]
  public var problems: [WBError]

  public init(devices: [Device], problems: [WBError]) {
    self.devices = devices
    self.problems = problems
  }
}
