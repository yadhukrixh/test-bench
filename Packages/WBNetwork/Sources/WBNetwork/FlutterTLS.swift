import Foundation

public enum FlutterTLS {
  public static let libraryName = "libflutter.so"
  public static let trusted = Data([0x20, 0x00, 0x80, 0x52, 0xC0, 0x03, 0x5F, 0xD6])

  public static func libraryPath(in names: [String]) -> String? {
    let matches = names.filter {
      $0.hasSuffix("/\(libraryName)") || $0 == libraryName
    }
    return matches.first { $0.contains("arm64-v8a") } ?? matches.first
  }

  public static func isBypassed(_ elf: Data) -> Bool {
    guard let file = ELF64(elf),
      let client = file.va(of: elf.range(of: Data("ssl_client\u{0}".utf8)))
    else { return false }
    for load in file.stringLoads(of: client) {
      for step in 0..<96 {
        let at = load - step * 4
        guard at >= 0, at + trusted.count <= elf.count else { continue }
        if elf[at..<(at + trusted.count)] == trusted { return true }
      }
    }
    return false
  }

  public static func bypass(_ elf: Data) throws -> Data {
    guard let offset = verifierOffset(in: elf) else {
      throw FlutterTLSError.verifierNotFound
    }
    var next = elf
    next.replaceSubrange(offset..<(offset + trusted.count), with: trusted)
    return next
  }

  public static func verifierOffset(in elf: Data) -> Int? {
    guard let file = ELF64(elf) else { return nil }
    guard let client = file.va(of: elf.range(of: Data("ssl_client\u{0}".utf8))) else {
      return nil
    }
    guard let server = file.va(of: elf.range(of: Data("ssl_server\u{0}".utf8))) else {
      return nil
    }
    let clientX = file.stringLoads(of: client)
    let serverX = file.stringLoads(of: server)
    var best: Int?
    for load in clientX {
      guard let start = file.functionStart(before: load) else { continue }
      let near = serverX.contains { abs($0 - start) < 0x300 || abs($0 - load) < 0x200 }
      guard near, file.storesAlert(at: start) else { continue }
      if elf[start..<(start + trusted.count)] == trusted { return start }
      best = start
    }
    return best
  }
}

public enum FlutterTLSError: Error, Equatable {
  case verifierNotFound
}

private struct ELF64 {
  let data: Data
  let loads: [(offset: Int, va: Int, size: Int, executable: Bool)]

  init?(_ data: Data) {
    guard data.count >= 64, data.starts(with: [0x7F, 0x45, 0x4C, 0x46]), data[4] == 2 else {
      return nil
    }
    let phoff = Int(data.u64(32))
    let phsize = Int(data.u16(54))
    let phnum = Int(data.u16(56))
    var loads: [(Int, Int, Int, Bool)] = []
    for index in 0..<phnum {
      let offset = phoff + index * phsize
      guard offset + 56 <= data.count else { return nil }
      if data.u32(offset) != 1 { continue }
      loads.append(
        (
          Int(data.u64(offset + 8)),
          Int(data.u64(offset + 16)),
          Int(data.u64(offset + 32)),
          data.u32(offset + 4) & 1 == 1
        )
      )
    }
    self.data = data
    self.loads = loads
  }

  func va(of range: Range<Data.Index>?) -> Int? {
    guard let range else { return nil }
    return va(ofFile: data.distance(from: data.startIndex, to: range.lowerBound))
  }

  func va(ofFile offset: Int) -> Int? {
    for load in loads where load.offset <= offset && offset < load.offset + load.size {
      return load.va + (offset - load.offset)
    }
    return nil
  }

  func file(ofVA va: Int) -> Int? {
    for load in loads where load.va <= va && va < load.va + load.size {
      return load.offset + (va - load.va)
    }
    return nil
  }

  func stringLoads(of target: Int) -> [Int] {
    var hits: [Int] = []
    let ranges = loads.filter(\.executable)
    let scan = ranges.isEmpty ? loads : ranges
    for load in scan {
      var offset = load.offset
      let end = min(data.count, load.offset + load.size)
      while offset + 8 <= end {
        guard offset % 4 == 0, let pc = va(ofFile: offset) else {
          offset += 4
          continue
        }
        if let dest = adrpAdd(at: offset, pc: pc), dest == target {
          hits.append(offset)
        }
        offset += 4
      }
    }
    return hits
  }

  func adrpAdd(at offset: Int, pc: Int) -> Int? {
    guard let page = Self.adrp(data.u32(offset), pc: pc) else { return nil }
    for step in 1...8 {
      let next = offset + step * 4
      guard next + 4 <= data.count, let add = Self.addImmediate(data.u32(next)) else { continue }
      if add.rn == page.rd {
        return page.page + add.imm
      }
    }
    return nil
  }

  func functionStart(before offset: Int) -> Int? {
    var found: Int?
    for step in 0..<96 {
      let at = offset - step * 4
      guard at >= 0 else { break }
      let instr = data.u32(at)
      if Self.isSubSP(instr) { return at }
      if Self.isPrologue(instr) {
        if found == nil { found = at }
      } else if found != nil, step > 8 {
        break
      }
    }
    return found
  }

  func storesAlert(at start: Int) -> Bool {
    for step in 0..<24 {
      let at = start + step * 4
      guard at + 4 <= data.count else { return false }
      if Self.strbX2(data.u32(at)) { return true }
    }
    return false
  }

  static func adrp(_ instr: UInt32, pc: Int) -> (rd: UInt32, page: Int)? {
    guard instr & 0x9F00_0000 == 0x9000_0000 else { return nil }
    let rd = instr & 0x1F
    let immlo = (instr >> 29) & 3
    let immhi = (instr >> 5) & 0x7_FFFF
    let imm = signExtend(Int((immhi << 2) | immlo) << 12, bits: 33)
    return (rd, (pc & ~0xFFF) + imm)
  }

  static func addImmediate(_ instr: UInt32) -> (rd: UInt32, rn: UInt32, imm: Int)? {
    guard instr & 0x7F80_0000 == 0x1100_0000 else { return nil }
    let rd = instr & 0x1F
    let rn = (instr >> 5) & 0x1F
    var imm = Int((instr >> 10) & 0xFFF)
    if (instr >> 22) & 1 == 1 { imm <<= 12 }
    return (rd, rn, imm)
  }

  static func isSubSP(_ instr: UInt32) -> Bool {
    instr & 0xFF80_03FF == 0xD100_03FF
  }

  static func isPrologue(_ instr: UInt32) -> Bool {
    if instr == 0xD503_233F { return true }
    if isSubSP(instr) { return true }
    if instr & 0xFFC0_7FFF == 0xA900_7BFD { return true }
    return false
  }

  static func strbX2(_ instr: UInt32) -> Bool {
    instr & 0xFFC0_03E0 == 0x3900_0040
  }

  static func signExtend(_ value: Int, bits: Int) -> Int {
    let sign = 1 << (bits - 1)
    return (value & (sign - 1)) - (value & sign)
  }
}

extension Data {
  fileprivate func u16(_ offset: Int) -> UInt16 {
    UInt16(self[startIndex.advanced(by: offset)])
      | UInt16(self[startIndex.advanced(by: offset + 1)]) << 8
  }

  fileprivate func u32(_ offset: Int) -> UInt32 {
    UInt32(self[startIndex.advanced(by: offset)])
      | UInt32(self[startIndex.advanced(by: offset + 1)]) << 8
      | UInt32(self[startIndex.advanced(by: offset + 2)]) << 16
      | UInt32(self[startIndex.advanced(by: offset + 3)]) << 24
  }

  fileprivate func u64(_ offset: Int) -> UInt64 {
    UInt64(u32(offset)) | UInt64(u32(offset + 4)) << 32
  }
}
