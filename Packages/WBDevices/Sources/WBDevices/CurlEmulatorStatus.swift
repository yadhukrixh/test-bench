import Foundation
import WBProcess

public protocol GuestReadyChecking: Sendable {
  func isBooted(grpcPort: Int) async -> Bool
}

public struct CurlEmulatorStatus: GuestReadyChecking {
  public var curl: URL
  public var runner: any CommandExecuting

  public init(curl: URL, runner: any CommandExecuting) {
    self.curl = curl
    self.runner = runner
  }

  public func isBooted(grpcPort: Int) async -> Bool {
    let folder = FileManager.default.temporaryDirectory
    let request = folder.appendingPathComponent("wb-grpc-req-\(grpcPort).bin")
    let body = folder.appendingPathComponent("wb-grpc-body-\(grpcPort).bin")
    let headers = folder.appendingPathComponent("wb-grpc-hdr-\(grpcPort).txt")
    defer {
      try? FileManager.default.removeItem(at: request)
      try? FileManager.default.removeItem(at: body)
      try? FileManager.default.removeItem(at: headers)
    }
    do {
      try Data(repeating: 0, count: 5).write(to: request)
      let result = try await runner.execute(
        executable: curl,
        arguments: [
          "--http2-prior-knowledge",
          "--silent",
          "--show-error",
          "--output", body.path,
          "--dump-header", headers.path,
          "--max-time", "5",
          "-H", "content-type: application/grpc",
          "-H", "te: trailers",
          "--data-binary", "@\(request.path)",
          "http://127.0.0.1:\(grpcPort)/android.emulation.control.EmulatorController/getStatus",
        ],
        timeout: .seconds(10),
        environment: nil
      )
      guard result.status == 0 else { return false }
      let headerText = (try? String(contentsOf: headers, encoding: .utf8)) ?? ""
      guard headerText.contains("grpc-status: 0") else { return false }
      let payload = (try? Data(contentsOf: body)) ?? Data()
      return GrpcStatusMessage.booted(grpcBody: payload) == true
    } catch {
      return false
    }
  }
}
