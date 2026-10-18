import CoreGraphics
import Foundation

public enum FrameImage {
  public static func cgImage(from frame: DeviceFrame) -> CGImage? {
    let width = frame.imageWidth
    let height = frame.imageHeight
    guard width > 0, height > 0, frame.rgba.count == width * height * 4 else { return nil }
    let provider = CGDataProvider(data: frame.rgba as CFData)
    guard let provider else { return nil }
    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  }
}
