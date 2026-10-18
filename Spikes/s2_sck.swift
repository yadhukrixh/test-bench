import CoreMedia
import Foundation
import ScreenCaptureKit

final class Box: NSObject, SCStreamOutput, @unchecked Sendable {
    var count = 0
    let started = CFAbsoluteTimeGetCurrent()
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, sampleBuffer.isValid else { return }
        count += 1
    }
}

@main
struct Main {
    static func main() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        let windows = content.windows.filter { window in
            let name = window.owningApplication?.applicationName ?? ""
            let title = window.title ?? ""
            return name.localizedCaseInsensitiveContains("Simulator")
                || title.localizedCaseInsensitiveContains("Simulator")
        }
        print("simulatorWindows \(windows.count) of \(content.windows.count)")
        for window in windows {
            let frame = window.frame
            print(
                "id=\(window.windowID) app=\(window.owningApplication?.applicationName ?? "") title=\(window.title ?? "") \(Int(frame.width))x\(Int(frame.height))"
            )
        }
        guard let window = windows.first else {
            fputs("no Simulator window\n", stderr)
            return
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = max(2, Int(window.frame.width) * 2)
        config.height = max(2, Int(window.frame.height) * 2)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = false
        let box = Box()
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(box, type: .screen, sampleHandlerQueue: .global())
        try await stream.startCapture()
        try await Task.sleep(nanoseconds: 3_000_000_000)
        try await stream.stopCapture()
        let elapsed = CFAbsoluteTimeGetCurrent() - box.started
        print("frames \(box.count) seconds \(String(format: "%.2f", elapsed)) fps \(String(format: "%.2f", Double(box.count) / elapsed))")
    }
}
