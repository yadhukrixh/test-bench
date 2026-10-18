import Foundation
import Testing

@testable import WBCore

struct WBCoreTests {
  @Test func scalesDevicePointsIntoTheView() {
    let geometry = DeviceGeometry(
      deviceWidth: 1080,
      deviceHeight: 2400,
      viewWidth: 270,
      viewHeight: 600
    )
    let view = geometry.viewPoint(deviceX: 540, deviceY: 1200)
    #expect(view?.x == 135)
    #expect(view?.y == 300)
    let device = geometry.devicePoint(viewX: 270, viewY: 600)
    #expect(device?.x == 1080)
    #expect(device?.y == 2400)
  }

  @Test func rejectsAZeroView() {
    let geometry = DeviceGeometry(deviceWidth: 100, deviceHeight: 100, viewWidth: 0, viewHeight: 10)
    #expect(geometry.devicePoint(viewX: 1, viewY: 1) == nil)
  }

  @Test func eventBusDeliversAPublishedValue() async {
    let bus = EventBus<String>()
    let stream = await bus.subscribe()
    await bus.publish("ready")
    var iterator = stream.makeAsyncIterator()
    let value = await iterator.next()
    #expect(value == "ready")
  }

  @Test func errorKeepsTheRecoverySuggestion() {
    let error = WBError(
      domain: .device,
      code: "boot.timeout",
      message: "Pixel_8 did not finish booting.",
      suggestion: "Start it again from the Device tab.",
      retryable: true
    )
    #expect(error.errorDescription == "Pixel_8 did not finish booting.")
    #expect(error.recoverySuggestion == "Start it again from the Device tab.")
    #expect(error.retryable)
  }
}
