import Foundation

public struct DeviceGeometry: Sendable, Equatable {
  public var deviceWidth: Double
  public var deviceHeight: Double
  public var viewWidth: Double
  public var viewHeight: Double

  public init(deviceWidth: Double, deviceHeight: Double, viewWidth: Double, viewHeight: Double) {
    self.deviceWidth = deviceWidth
    self.deviceHeight = deviceHeight
    self.viewWidth = viewWidth
    self.viewHeight = viewHeight
  }

  public func viewPoint(deviceX: Double, deviceY: Double) -> (x: Double, y: Double)? {
    guard deviceWidth > 0, deviceHeight > 0 else { return nil }
    return (deviceX / deviceWidth * viewWidth, deviceY / deviceHeight * viewHeight)
  }

  public func devicePoint(viewX: Double, viewY: Double) -> (x: Double, y: Double)? {
    guard viewWidth > 0, viewHeight > 0 else { return nil }
    return (viewX / viewWidth * deviceWidth, viewY / viewHeight * deviceHeight)
  }
}
