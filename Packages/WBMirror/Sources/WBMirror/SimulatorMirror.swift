import CoreGraphics
import Foundation
import ImageIO
import WBProcess

public actor SimulatorMirror: FrameSource {
  private let udid: String
  private let xcrun: URL
  private let runner: any CommandExecuting
  private var producer: Task<Void, Never>?

  public init(udid: String, xcrun: URL, runner: any CommandExecuting) {
    self.udid = udid
    self.xcrun = xcrun
    self.runner = runner
  }

  public func frames() -> AsyncStream<MirrorEvent> {
    let udid = self.udid
    let xcrun = self.xcrun
    let runner = self.runner
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let task = Task {
        let folder = FileManager.default.temporaryDirectory
        while !Task.isCancelled {
          let file = folder.appendingPathComponent("wb-sim-\(UUID().uuidString).png")
          let result = try? await runner.execute(
            executable: xcrun,
            arguments: ["simctl", "io", udid, "screenshot", file.path],
            timeout: .seconds(8),
            environment: nil
          )
          if result?.status == 0, let data = try? Data(contentsOf: file),
            let frame = Self.decode(data)
          {
            continuation.yield(.frame(frame))
          }
          try? FileManager.default.removeItem(at: file)
          do {
            try await Task.sleep(for: .milliseconds(400))
          } catch {
            break
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
      Task { await self.remember(task) }
    }
  }

  public func stop() {
    producer?.cancel()
    producer = nil
  }

  private func remember(_ task: Task<Void, Never>) async {
    producer = task
  }

  static func decode(_ data: Data) -> DeviceFrame? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    guard
      let context = CGContext(
        data: &bytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue
      )
    else { return nil }
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return DeviceFrame(
      imageWidth: width,
      imageHeight: height,
      deviceWidth: width,
      deviceHeight: height,
      rgba: Data(bytes),
      sequence: 0
    )
  }
}
