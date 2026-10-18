import Foundation

enum Protobuf {
  static func varint(_ value: UInt64) -> Data {
    var rest = value
    var bytes = Data()
    repeat {
      var byte = UInt8(rest & 0x7F)
      rest >>= 7
      if rest != 0 { byte |= 0x80 }
      bytes.append(byte)
    } while rest != 0
    return bytes
  }

  static func fieldVarint(_ field: Int, _ value: UInt64) -> Data {
    var data = varint(UInt64((field << 3) | 0))
    data.append(varint(value))
    return data
  }

  static func fieldBytes(_ field: Int, _ value: Data) -> Data {
    var data = varint(UInt64((field << 3) | 2))
    data.append(varint(UInt64(value.count)))
    data.append(value)
    return data
  }

  static func fieldString(_ field: Int, _ value: String) -> Data {
    fieldBytes(field, Data(value.utf8))
  }

  static func imageFormat(width: UInt32, height: UInt32) -> Data {
    var data = fieldVarint(1, 1)
    data.append(fieldVarint(3, UInt64(width)))
    data.append(fieldVarint(4, UInt64(height)))
    return data
  }

  static func touch(x: Int32, y: Int32, identifier: Int32, pressure: Int32) -> Data {
    var point = fieldSigned(1, x)
    point.append(fieldSigned(2, y))
    point.append(fieldSigned(3, identifier))
    point.append(fieldSigned(4, pressure))
    return fieldBytes(1, point)
  }

  static func fieldSigned(_ field: Int, _ value: Int32) -> Data {
    fieldVarint(field, UInt64(bitPattern: Int64(value)))
  }

  static func keypress(_ key: String) -> Data {
    var data = fieldVarint(2, 2)
    data.append(fieldString(4, key))
    return data
  }
}

enum ClipDataMessage {
  static func encode(_ text: String) -> Data {
    Protobuf.fieldString(1, text)
  }

  static func decode(_ data: Data) -> String {
    let bytes = [UInt8](data)
    var index = 0
    while index < bytes.count {
      guard let key = readVarint(bytes, &index) else { return "" }
      let field = Int(key >> 3)
      let wire = Int(key & 7)
      switch wire {
      case 0:
        guard readVarint(bytes, &index) != nil else { return "" }
      case 2:
        guard let length = readVarint(bytes, &index) else { return "" }
        let end = index + Int(length)
        guard end <= bytes.count else { return "" }
        if field == 1 {
          return String(decoding: bytes[index..<end], as: UTF8.self)
        }
        index = end
      case 5:
        index += 4
      case 1:
        index += 8
      default:
        return ""
      }
    }
    return ""
  }

  private static func readVarint(_ bytes: [UInt8], _ index: inout Int) -> UInt64? {
    var result: UInt64 = 0
    var shift: UInt64 = 0
    while index < bytes.count, shift <= 63 {
      let byte = bytes[index]
      index += 1
      result |= UInt64(byte & 0x7F) << shift
      if byte & 0x80 == 0 { return result }
      shift += 7
    }
    return nil
  }
}

public struct Screenshot: Sendable, Equatable {
  public var width: Int
  public var height: Int
  public var pixels: Data
  public var sequence: UInt32

  public init(width: Int, height: Int, pixels: Data, sequence: UInt32) {
    self.width = width
    self.height = height
    self.pixels = pixels
    self.sequence = sequence
  }
}

enum ScreenshotMessage {
  static func decode(_ data: Data) -> Screenshot? {
    let bytes = [UInt8](data)
    var index = 0
    var width = 0
    var height = 0
    var pixels = Data()
    var sequence: UInt32 = 0
    while index < bytes.count {
      guard let key = varint(bytes, &index) else { return nil }
      let field = Int(key >> 3)
      let wire = Int(key & 7)
      switch wire {
      case 0:
        guard let value = varint(bytes, &index) else { return nil }
        if field == 2 { width = Int(value) }
        if field == 3 { height = Int(value) }
        if field == 5 { sequence = UInt32(value) }
      case 2:
        guard let length = varint(bytes, &index) else { return nil }
        let end = index + Int(length)
        guard end <= bytes.count else { return nil }
        let slice = Data(bytes[index..<end])
        if field == 1 {
          let nested = nestedSize(slice)
          if nested.width > 0 { width = nested.width }
          if nested.height > 0 { height = nested.height }
        } else if field == 4 {
          pixels = slice
        }
        index = end
      case 5:
        index += 4
      case 1:
        index += 8
      default:
        return nil
      }
      if index > bytes.count { return nil }
    }
    guard width > 0, height > 0, pixels.count == width * height * 4 else { return nil }
    return Screenshot(width: width, height: height, pixels: pixels, sequence: sequence)
  }

  private static func nestedSize(_ data: Data) -> (width: Int, height: Int) {
    let bytes = [UInt8](data)
    var index = 0
    var width = 0
    var height = 0
    while index < bytes.count {
      guard let key = varint(bytes, &index) else { break }
      let field = Int(key >> 3)
      let wire = Int(key & 7)
      switch wire {
      case 0:
        guard let value = varint(bytes, &index) else { return (width, height) }
        if field == 3 { width = Int(value) }
        if field == 4 { height = Int(value) }
      case 2:
        guard let length = varint(bytes, &index) else { return (width, height) }
        index += Int(length)
      case 5:
        index += 4
      case 1:
        index += 8
      default:
        return (width, height)
      }
    }
    return (width, height)
  }

  private static func varint(_ bytes: [UInt8], _ index: inout Int) -> UInt64? {
    var result: UInt64 = 0
    var shift: UInt64 = 0
    while index < bytes.count, shift <= 63 {
      let byte = bytes[index]
      index += 1
      result |= UInt64(byte & 0x7F) << shift
      if byte & 0x80 == 0 { return result }
      shift += 7
    }
    return nil
  }
}

enum DisplaySizeText {
  static func parse(_ text: String) -> (width: Int, height: Int)? {
    let lines = text.split(whereSeparator: \.isNewline).map(String.init)
    let override = lines.first { $0.contains("Override size:") }
    let physical = lines.first { $0.contains("Physical size:") }
    let chosen = override ?? physical ?? ""
    guard let range = chosen.range(of: #"(\d+)x(\d+)"#, options: .regularExpression) else {
      return nil
    }
    let parts = chosen[range].split(separator: "x")
    guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0,
      height > 0
    else { return nil }
    return (width, height)
  }
}

enum PixelOrder {
  static func topDown(_ pixels: Data, width: Int, height: Int) -> Data {
    let row = width * 4
    guard pixels.count == row * height, height > 0 else { return pixels }
    var output = Data(count: pixels.count)
    for y in 0..<height {
      let source = pixels.index(pixels.startIndex, offsetBy: (height - 1 - y) * row)
      let target = output.index(output.startIndex, offsetBy: y * row)
      output.replaceSubrange(
        target..<output.index(target, offsetBy: row),
        with: pixels[source..<pixels.index(source, offsetBy: row)])
    }
    return output
  }
}
