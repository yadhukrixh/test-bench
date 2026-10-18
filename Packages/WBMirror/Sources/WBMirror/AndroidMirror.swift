import Foundation
import WBCore
import WBProcess

public struct DeviceFrame: Sendable, Equatable {
  public var imageWidth: Int
  public var imageHeight: Int
  public var deviceWidth: Int
  public var deviceHeight: Int
  public var rgba: Data
  public var sequence: UInt32

  public init(
    imageWidth: Int,
    imageHeight: Int,
    deviceWidth: Int,
    deviceHeight: Int,
    rgba: Data,
    sequence: UInt32
  ) {
    self.imageWidth = imageWidth
    self.imageHeight = imageHeight
    self.deviceWidth = deviceWidth
    self.deviceHeight = deviceHeight
    self.rgba = rgba
    self.sequence = sequence
  }
}

public struct EmulatorControl: Sendable {
  public var port: Int
  public var client: GrpcClient

  public init(port: Int, client: GrpcClient = GrpcClient()) {
    self.port = port
    self.client = client
  }

  public func screenshot(width: Int, height: Int) async throws -> Screenshot {
    let payload = try await client.unary(
      port: port,
      path: "/android.emulation.control.EmulatorController/getScreenshot",
      message: Protobuf.imageFormat(width: UInt32(width), height: UInt32(height))
    )
    guard let shot = ScreenshotMessage.decode(payload) else {
      throw WBError(
        domain: .parse,
        code: "screenshot.decode",
        message: "The emulator sent a frame that could not be read."
      )
    }
    return shot
  }

  public func frames(width: Int, height: Int) -> GrpcServerStream<Screenshot> {
    let messages = client.serverStream(
      port: port,
      path: "/android.emulation.control.EmulatorController/streamScreenshot",
      message: Protobuf.imageFormat(width: UInt32(width), height: UInt32(height))
    )
    let shots = AsyncThrowingStream<Screenshot, Error> { continuation in
      let task = Task {
        do {
          for try await message in messages.messages {
            if Task.isCancelled { break }
            if let shot = ScreenshotMessage.decode(message) {
              continuation.yield(shot)
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in
        messages.cancel()
        task.cancel()
      }
    }
    return GrpcServerStream(messages: shots, cancelBody: { messages.cancel() })
  }

  public func touch(x: Int, y: Int, pressure: Int, identifier: Int = 1) async throws {
    _ = try await client.unary(
      port: port,
      path: "/android.emulation.control.EmulatorController/sendTouch",
      message: Protobuf.touch(
        x: Int32(x), y: Int32(y), identifier: Int32(identifier), pressure: Int32(pressure))
    )
  }

  public func key(_ key: String) async throws {
    _ = try await client.unary(
      port: port,
      path: "/android.emulation.control.EmulatorController/sendKey",
      message: Protobuf.keypress(key)
    )
  }

  public func setClipboard(_ text: String) async throws {
    _ = try await client.unary(
      port: port,
      path: "/android.emulation.control.EmulatorController/setClipboard",
      message: ClipDataMessage.encode(text)
    )
  }

  public func getClipboard() async throws -> String {
    let payload = try await client.unary(
      port: port,
      path: "/android.emulation.control.EmulatorController/getClipboard",
      message: Data()
    )
    return ClipDataMessage.decode(payload)
  }
}

public enum MirrorEvent: Sendable {
  case frame(DeviceFrame)
  case failed(String)
}

public protocol FrameSource: Sendable {
  func frames() async -> AsyncStream<MirrorEvent>
  func stop() async
}

public protocol InputSink: Sendable {
  func tap(x: Int, y: Int) async throws
  func key(_ name: String) async throws
}

public actor AndroidMirror: FrameSource, InputSink {
  private let control: EmulatorControl
  private let serial: String
  private let adb: URL
  private let runner: any CommandExecuting
  private var streamCancel: (@Sendable () -> Void)?

  public init(grpcPort: Int, serial: String, adb: URL, runner: any CommandExecuting) {
    self.control = EmulatorControl(port: grpcPort)
    self.serial = serial
    self.adb = adb
    self.runner = runner
  }

  public func fullFrame() async throws -> DeviceFrame {
    let device = try await deviceSize()
    let shot = try await control.screenshot(width: device.width, height: device.height)
    return Self.frame(shot, device: device)
  }

  public func frames() -> AsyncStream<MirrorEvent> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let task = Task { await self.produce(continuation) }
      continuation.onTermination = { _ in
        task.cancel()
        Task { await self.stop() }
      }
    }
  }

  public func stop() {
    streamCancel?()
    streamCancel = nil
  }

  private func produce(_ continuation: AsyncStream<MirrorEvent>.Continuation) async {
    var sawFrame = false
    do {
      let device = try await deviceSize()
      let scaled = Self.scaled(device)
      if let shot = try? await control.screenshot(width: scaled.width, height: scaled.height) {
        sawFrame = true
        continuation.yield(.frame(Self.frame(shot, device: device)))
      }
      let shots = control.frames(width: scaled.width, height: scaled.height)
      streamCancel = { shots.cancel() }
      for try await shot in shots.messages {
        if Task.isCancelled { break }
        sawFrame = true
        continuation.yield(.frame(Self.frame(shot, device: device)))
      }
    } catch {
      if !sawFrame {
        let message =
          (error as? WBError)?.message ?? "The emulator frame stream stopped."
        continuation.yield(.failed(message))
      }
    }
    streamCancel = nil
    continuation.finish()
  }

  public func tap(x: Int, y: Int) async throws {
    try await control.touch(x: x, y: y, pressure: 1)
    try await control.touch(x: x, y: y, pressure: 0)
  }

  public func move(x: Int, y: Int, pressure: Int) async throws {
    try await control.touch(x: x, y: y, pressure: pressure)
  }

  public func key(_ key: String) async throws {
    try await control.key(key)
  }

  public func clipboard() async throws -> String {
    try await control.getClipboard()
  }

  public func setClipboard(_ text: String) async throws {
    try await control.setClipboard(text)
  }

  private func deviceSize() async throws -> (width: Int, height: Int) {
    let result = try await runner.execute(
      executable: adb,
      arguments: ["-s", serial, "shell", "wm", "size"],
      timeout: .seconds(8),
      environment: nil
    )
    guard let size = DisplaySizeText.parse(result.stdoutText) else {
      throw WBError(
        domain: .parse,
        code: "display.size",
        message: "Could not read the emulator display size.",
        suggestion: result.stderrText
      )
    }
    return size
  }

  private static func scaled(_ device: (width: Int, height: Int)) -> (width: Int, height: Int) {
    let width = max(1, device.width / 2)
    let height = max(1, device.height / 2)
    return (width, height)
  }

  private static func frame(_ shot: Screenshot, device: (width: Int, height: Int)) -> DeviceFrame {
    DeviceFrame(
      imageWidth: shot.width,
      imageHeight: shot.height,
      deviceWidth: device.width,
      deviceHeight: device.height,
      rgba: shot.pixels,
      sequence: shot.sequence
    )
  }
}
