import Foundation
import Testing

@testable import WBMirror

struct CodecTests {
  @Test func encodesAScaledScreenshotRequest() {
    let format = Protobuf.imageFormat(width: 540, height: 1200)
    #expect(format.starts(with: Data([0x08, 0x01])))
    #expect(format.contains(Data([0x18, 0x9C, 0x04])))
  }

  @Test func decodesAnImage() {
    var message = Protobuf.fieldVarint(2, 1)
    message.append(Protobuf.fieldVarint(3, 2))
    let first = Data([1, 0, 0, 255])
    let second = Data([0, 1, 0, 255])
    message.append(Protobuf.fieldBytes(4, first + second))
    message.append(Protobuf.fieldVarint(5, 4))
    let shot = ScreenshotMessage.decode(message)
    #expect(shot?.width == 1)
    #expect(shot?.height == 2)
    #expect(shot?.sequence == 4)
    #expect(shot?.pixels.prefix(4) == first)
  }

  @Test func readsSizeFromTheNestedFormat() {
    let format = Protobuf.imageFormat(width: 2, height: 1)
    var message = Protobuf.fieldBytes(1, format)
    message.append(Protobuf.fieldBytes(4, Data(repeating: 9, count: 8)))
    let shot = ScreenshotMessage.decode(message)
    #expect(shot?.width == 2)
    #expect(shot?.height == 1)
    #expect(shot?.pixels.count == 8)
  }

  @Test func prefersOverrideSize() {
    let text = """
      Physical size: 1080x2400
      Override size: 720x1280
      """
    #expect(DisplaySizeText.parse(text)?.width == 720)
    #expect(DisplaySizeText.parse(text)?.height == 1280)
    #expect(DisplaySizeText.parse("Physical size: 1080x2400")?.width == 1080)
    #expect(DisplaySizeText.parse("no size") == nil)
  }

  @Test func headerBlockNamesTheCall() {
    let block = HPACK.request(
      authority: "127.0.0.1:8554",
      path: "/android.emulation.control.EmulatorController/getScreenshot"
    )
    #expect(block.contains(Data("application/grpc".utf8)))
    #expect(
      block.contains(Data("/android.emulation.control.EmulatorController/getScreenshot".utf8)))
    #expect(block.contains(Data("trailers".utf8)))
  }

  @Test func encodesAndDecodesClipboardText() {
    let encoded = ClipDataMessage.encode("hello")
    #expect(encoded.first == 0x0A)
    #expect(ClipDataMessage.decode(encoded) == "hello")
    #expect(ClipDataMessage.decode(Data()) == "")
    let press = Protobuf.keypress("AudioVolumeUp")
    #expect(press.contains(Data("AudioVolumeUp".utf8)))
  }

  @Test func framesRoundTrip() {
    let payload = Data([0x0A, 0x0B])
    let encoded = HTTP2.frame(
      type: HTTP2.dataType, flags: HTTP2.endStream, stream: 1, payload: payload)
    var buffer = encoded + Data([0x00])
    let frame = HTTP2.consume(&buffer)
    #expect(frame?.type == HTTP2.dataType)
    #expect(frame?.flags == HTTP2.endStream)
    #expect(frame?.stream == 1)
    #expect(frame?.payload == payload)
    #expect(HTTP2.consume(&buffer) == nil)

    var body = HTTP2.grpcBody(Data([0x18, 0x01]))
    body.append(HTTP2.grpcBody(Data()))
    #expect(HTTP2.nextGrpcMessage(&body) == Data([0x18, 0x01]))
    #expect(HTTP2.nextGrpcMessage(&body) == Data())
    #expect(HTTP2.nextGrpcMessage(&body) == nil)
  }
}

struct LiveMirrorTests {
  @Test func readsOneScreenshotWhenAsked() async throws {
    guard let portText = ProcessInfo.processInfo.environment["WB_GRPC_PORT"],
      let port = Int(portText)
    else {
      return
    }
    let control = EmulatorControl(port: port)
    let shot = try await control.screenshot(width: 180, height: 400)
    #expect(shot.width > 0)
    #expect(shot.height > 0)
    #expect(shot.pixels.count == shot.width * shot.height * 4)
    let streamed = control.frames(width: 180, height: 400)
    let first = try await withThrowingTaskGroup(of: Screenshot?.self) { group in
      group.addTask {
        for try await frame in streamed.messages {
          return frame
        }
        return nil
      }
      group.addTask {
        try await Task.sleep(for: .milliseconds(300))
        try await control.key("GoHome")
        try await Task.sleep(for: .seconds(6))
        streamed.cancel()
        return nil
      }
      let value = try await group.next() ?? nil
      group.cancelAll()
      streamed.cancel()
      return value
    }
    #expect(first?.width ?? 0 > 0)
  }
}
