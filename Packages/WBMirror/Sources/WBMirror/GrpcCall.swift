import Foundation
import Network
import WBCore

public struct GrpcClient: Sendable {
  public init() {}

  public func unary(port: Int, path: String, message: Data, timeout: Duration = .seconds(8))
    async throws -> Data
  {
    let call = GrpcCall(port: port, path: path, message: message)
    return try await withThrowingTaskGroup(of: Data.self) { group in
      group.addTask { try await call.unary() }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw WBError(
          domain: .source,
          code: "grpc.timeout",
          message: "The emulator did not answer \(path).",
          suggestion: "Boot the device again if this keeps happening.",
          retryable: true
        )
      }
      defer {
        group.cancelAll()
        call.cancel()
      }
      guard let result = try await group.next() else {
        throw WBError(
          domain: .source, code: "grpc.empty", message: "The emulator call returned nothing.")
      }
      return result
    }
  }

  public func serverStream(port: Int, path: String, message: Data) -> GrpcServerStream<Data> {
    let call = GrpcCall(port: port, path: path, message: message)
    let messages = AsyncThrowingStream<Data, Error> { continuation in
      call.onMessage = { continuation.yield($0) }
      call.onFinished = { error in
        if let error {
          continuation.finish(throwing: error)
        } else {
          continuation.finish()
        }
      }
      call.startStream()
      continuation.onTermination = { _ in call.cancel() }
    }
    return GrpcServerStream(messages: messages, cancelBody: { call.cancel() })
  }
}

public struct GrpcServerStream<Element: Sendable>: Sendable {
  public var messages: AsyncThrowingStream<Element, Error>
  private let cancelBody: @Sendable () -> Void

  public init(
    messages: AsyncThrowingStream<Element, Error>, cancelBody: @escaping @Sendable () -> Void
  ) {
    self.messages = messages
    self.cancelBody = cancelBody
  }

  public func cancel() {
    cancelBody()
  }
}

final class GrpcCall: @unchecked Sendable {
  var onMessage: (@Sendable (Data) -> Void)?
  var onFinished: (@Sendable (Error?) -> Void)?

  private let queue = DispatchQueue(label: "com.qaworkbench.grpc")
  private let port: Int
  private let path: String
  private let message: Data
  private var connection: NWConnection?
  private var incoming = Data()
  private var grpcBuffer = Data()
  private var requestSent = false
  private var finished = false
  private var waiter: CheckedContinuation<Data, Error>?
  private var unaryMessage: Data?
  private var streaming = false
  private var windowDebt = 0

  init(port: Int, path: String, message: Data) {
    self.port = port
    self.path = path
    self.message = message
  }

  func unary() async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      queue.sync {
        self.waiter = continuation
      }
      open()
    }
  }

  func startStream() {
    queue.sync {
      self.streaming = true
    }
    open()
  }

  func cancel() {
    queue.async {
      self.fail(CancellationError())
      self.connection?.cancel()
    }
  }

  private func open() {
    guard let endpoint = NWEndpoint.Port(rawValue: UInt16(port)) else {
      fail(WBError(domain: .source, code: "grpc.port", message: "gRPC port \(port) is not valid."))
      return
    }
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    let parameters = NWParameters(tls: nil, tcp: tcp)
    let connection = NWConnection(
      host: NWEndpoint.Host("127.0.0.1"), port: endpoint, using: parameters)
    self.connection = connection
    connection.stateUpdateHandler = { [weak self] state in
      self?.handle(state)
    }
    connection.start(queue: queue)
  }

  private func handle(_ state: NWConnection.State) {
    switch state {
    case .ready:
      sendRequest()
      receive()
    case .failed(let error):
      fail(
        WBError(
          domain: .source, code: "grpc.connect", message: "Could not reach the emulator.",
          underlying: String(describing: error), retryable: true))
    case .cancelled:
      fail(CancellationError())
    default:
      break
    }
  }

  private func sendRequest() {
    guard !requestSent else { return }
    requestSent = true
    var bytes = HTTP2.preface
    bytes.append(HTTP2.frame(type: HTTP2.settingsType, flags: 0, stream: 0, payload: Data()))
    bytes.append(HTTP2.windowUpdate(stream: 0, increment: 32 * 1024 * 1024))
    let headers = HPACK.request(authority: "127.0.0.1:\(port)", path: path)
    bytes.append(
      HTTP2.frame(type: HTTP2.headersType, flags: HTTP2.endHeaders, stream: 1, payload: headers))
    bytes.append(HTTP2.windowUpdate(stream: 1, increment: 32 * 1024 * 1024))
    bytes.append(
      HTTP2.frame(
        type: HTTP2.dataType, flags: HTTP2.endStream, stream: 1, payload: HTTP2.grpcBody(message))
    )
    connection?.send(content: bytes, completion: .contentProcessed { _ in })
  }

  private func receive() {
    connection?.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) {
      [weak self] data, _, complete, error in
      guard let self else { return }
      if let data, !data.isEmpty {
        self.incoming.append(data)
        self.pump()
      }
      if let error {
        self.fail(
          WBError(
            domain: .source, code: "grpc.read", message: "The emulator closed the frame stream.",
            underlying: String(describing: error)))
        return
      }
      if complete {
        self.succeedEnd()
        return
      }
      if !self.finished {
        self.receive()
      }
    }
  }

  private func pump() {
    while let frame = HTTP2.consume(&incoming) {
      switch frame.type {
      case HTTP2.settingsType:
        if frame.flags & HTTP2.ack == 0 {
          connection?.send(
            content: HTTP2.frame(
              type: HTTP2.settingsType, flags: HTTP2.ack, stream: 0, payload: Data()),
            completion: .contentProcessed { _ in }
          )
        }
      case HTTP2.pingType:
        if frame.flags & HTTP2.ack == 0 {
          connection?.send(
            content: HTTP2.frame(
              type: HTTP2.pingType, flags: HTTP2.ack, stream: 0, payload: frame.payload),
            completion: .contentProcessed { _ in }
          )
        }
      case HTTP2.dataType:
        var payload = frame.payload
        if frame.flags & HTTP2.padded != 0, let pad = payload.first {
          payload.removeFirst()
          if pad > 0, payload.count >= Int(pad) {
            payload.removeLast(Int(pad))
          }
        }
        grpcBuffer.append(payload)
        windowDebt += payload.count
        while let message = HTTP2.nextGrpcMessage(&grpcBuffer) {
          deliver(message)
        }
        if windowDebt > 16_384 {
          let credit = windowDebt
          windowDebt = 0
          connection?.send(
            content: HTTP2.windowUpdate(stream: 0, increment: credit),
            completion: .contentProcessed { _ in })
          connection?.send(
            content: HTTP2.windowUpdate(stream: frame.stream, increment: credit),
            completion: .contentProcessed { _ in })
        }
        if frame.flags & HTTP2.endStream != 0 {
          succeedEnd()
        }
      case HTTP2.headersType:
        if frame.payload.contains(Data("grpc-status".utf8)),
          let status = grpcStatus(in: frame.payload), status != 0
        {
          fail(
            WBError(
              domain: .source, code: "grpc.status",
              message: "The emulator rejected the call (\(status))."))
        }
        if frame.flags & HTTP2.endStream != 0 {
          succeedEnd()
        }
      case HTTP2.goawayType, 0x3:
        fail(
          WBError(
            domain: .source, code: "grpc.reset", message: "The emulator reset the frame stream.",
            retryable: true))
      default:
        break
      }
    }
  }

  private func deliver(_ message: Data) {
    if streaming {
      onMessage?(message)
    } else if unaryMessage == nil {
      unaryMessage = message
      succeedEnd()
    }
  }

  private func grpcStatus(in payload: Data) -> Int? {
    guard let text = String(data: payload, encoding: .utf8) else { return nil }
    guard let range = text.range(of: "grpc-status") else { return nil }
    let tail = text[range.upperBound...]
    let digits = tail.prefix { $0.isNumber || $0 == " " || $0 == ":" }
    return Int(digits.filter(\.isNumber))
  }

  private func succeedEnd() {
    guard !finished else { return }
    finished = true
    if let waiter {
      self.waiter = nil
      waiter.resume(returning: unaryMessage ?? Data())
    }
    onFinished?(nil)
    connection?.cancel()
  }

  private func fail(_ error: Error) {
    guard !finished else { return }
    finished = true
    if let waiter {
      self.waiter = nil
      waiter.resume(throwing: error)
    }
    onFinished?(error)
    connection?.cancel()
  }
}
