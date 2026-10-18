import Foundation

enum HTTP2 {
  static let preface = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
  static let dataType: UInt8 = 0x0
  static let headersType: UInt8 = 0x1
  static let settingsType: UInt8 = 0x4
  static let pingType: UInt8 = 0x6
  static let goawayType: UInt8 = 0x7
  static let windowType: UInt8 = 0x8
  static let endStream: UInt8 = 0x1
  static let ack: UInt8 = 0x1
  static let endHeaders: UInt8 = 0x4
  static let padded: UInt8 = 0x8

  struct Frame: Equatable {
    var type: UInt8
    var flags: UInt8
    var stream: Int
    var payload: Data
  }

  static func frame(type: UInt8, flags: UInt8, stream: Int, payload: Data) -> Data {
    var out = Data()
    let length = payload.count
    out.append(UInt8((length >> 16) & 0xFF))
    out.append(UInt8((length >> 8) & 0xFF))
    out.append(UInt8(length & 0xFF))
    out.append(type)
    out.append(flags)
    let id = UInt32(stream) & 0x7FFF_FFFF
    out.append(UInt8((id >> 24) & 0xFF))
    out.append(UInt8((id >> 16) & 0xFF))
    out.append(UInt8((id >> 8) & 0xFF))
    out.append(UInt8(id & 0xFF))
    out.append(payload)
    return out
  }

  static func consume(_ buffer: inout Data) -> Frame? {
    guard buffer.count >= 9 else { return nil }
    let length =
      (Int(buffer[buffer.startIndex]) << 16)
      | (Int(buffer[buffer.startIndex + 1]) << 8)
      | Int(buffer[buffer.startIndex + 2])
    guard buffer.count >= 9 + length else { return nil }
    let type = buffer[buffer.startIndex + 3]
    let flags = buffer[buffer.startIndex + 4]
    let stream =
      (Int(buffer[buffer.startIndex + 5]) << 24)
      | (Int(buffer[buffer.startIndex + 6]) << 16)
      | (Int(buffer[buffer.startIndex + 7]) << 8)
      | Int(buffer[buffer.startIndex + 8])
    let start = buffer.index(buffer.startIndex, offsetBy: 9)
    let end = buffer.index(start, offsetBy: length)
    let payload = Data(buffer[start..<end])
    buffer.removeSubrange(buffer.startIndex..<end)
    return Frame(type: type, flags: flags, stream: stream & 0x7FFF_FFFF, payload: payload)
  }

  static func windowUpdate(stream: Int, increment: Int) -> Data {
    var payload = Data()
    let value = UInt32(increment) & 0x7FFF_FFFF
    payload.append(UInt8((value >> 24) & 0xFF))
    payload.append(UInt8((value >> 16) & 0xFF))
    payload.append(UInt8((value >> 8) & 0xFF))
    payload.append(UInt8(value & 0xFF))
    return frame(type: windowType, flags: 0, stream: stream, payload: payload)
  }

  static func grpcBody(_ message: Data) -> Data {
    var body = Data([0])
    let length = UInt32(message.count)
    body.append(UInt8((length >> 24) & 0xFF))
    body.append(UInt8((length >> 16) & 0xFF))
    body.append(UInt8((length >> 8) & 0xFF))
    body.append(UInt8(length & 0xFF))
    body.append(message)
    return body
  }

  static func nextGrpcMessage(_ buffer: inout Data) -> Data? {
    guard buffer.count >= 5 else { return nil }
    let length =
      (Int(buffer[buffer.startIndex + 1]) << 24)
      | (Int(buffer[buffer.startIndex + 2]) << 16)
      | (Int(buffer[buffer.startIndex + 3]) << 8)
      | Int(buffer[buffer.startIndex + 4])
    guard buffer.count >= 5 + length else { return nil }
    let start = buffer.index(buffer.startIndex, offsetBy: 5)
    let end = buffer.index(start, offsetBy: length)
    let message = Data(buffer[start..<end])
    buffer.removeSubrange(buffer.startIndex..<end)
    return message
  }
}

enum HPACK {
  static func request(authority: String, path: String) -> Data {
    var block = Data([0x83, 0x86])
    block.append(indexedLiteral(nameIndex: 1, value: authority))
    block.append(indexedLiteral(nameIndex: 4, value: path))
    block.append(indexedLiteral(nameIndex: 31, value: "application/grpc"))
    block.append(newLiteral(name: "te", value: "trailers"))
    return block
  }

  static func indexedLiteral(nameIndex: Int, value: String) -> Data {
    var data = Data()
    if nameIndex < 15 {
      data.append(UInt8(nameIndex))
    } else {
      data.append(0x0F)
      data.append(UInt8(nameIndex - 15))
    }
    data.append(string(value))
    return data
  }

  static func newLiteral(name: String, value: String) -> Data {
    var data = Data([0x00])
    data.append(string(name))
    data.append(string(value))
    return data
  }

  private static func string(_ value: String) -> Data {
    let bytes = Data(value.utf8)
    var data = Data([UInt8(bytes.count)])
    data.append(bytes)
    return data
  }
}
