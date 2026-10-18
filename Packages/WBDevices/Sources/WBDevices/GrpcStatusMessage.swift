import Foundation

public enum GrpcStatusMessage {
  public static func booted(grpcBody: Data) -> Bool? {
    guard grpcBody.count >= 5, grpcBody[grpcBody.startIndex] == 0 else {
      return nil
    }
    let length =
      Int(grpcBody[grpcBody.startIndex + 1]) << 24
      | Int(grpcBody[grpcBody.startIndex + 2]) << 16
      | Int(grpcBody[grpcBody.startIndex + 3]) << 8
      | Int(grpcBody[grpcBody.startIndex + 4])
    let messageStart = 5
    let messageEnd = min(grpcBody.count, messageStart + length)
    guard messageEnd > messageStart else { return nil }
    return boolField(3, in: Array(grpcBody[messageStart..<messageEnd]))
  }

  static func boolField(_ fieldNumber: Int, in bytes: [UInt8]) -> Bool? {
    var index = 0
    while index < bytes.count {
      guard let key = varint(bytes, &index) else { return nil }
      let field = Int(key >> 3)
      let wire = Int(key & 7)
      switch wire {
      case 0:
        guard let value = varint(bytes, &index) else { return nil }
        if field == fieldNumber {
          return value != 0
        }
      case 1:
        index += 8
      case 2:
        guard let length = varint(bytes, &index) else { return nil }
        index += Int(length)
      case 5:
        index += 4
      default:
        return nil
      }
      if index > bytes.count {
        return nil
      }
    }
    return nil
  }

  private static func varint(_ bytes: [UInt8], _ index: inout Int) -> UInt64? {
    var result: UInt64 = 0
    var shift: UInt64 = 0
    while index < bytes.count, shift <= 63 {
      let byte = bytes[index]
      index += 1
      result |= UInt64(byte & 0x7F) << shift
      if byte & 0x80 == 0 {
        return result
      }
      shift += 7
    }
    return nil
  }
}
