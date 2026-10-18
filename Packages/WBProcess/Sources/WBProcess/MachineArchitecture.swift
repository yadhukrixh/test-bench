import Darwin
import Foundation

enum MachineArchitecture {
  static func current() -> String {
    var system = utsname()
    uname(&system)
    return withUnsafePointer(to: &system.machine) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
        String(cString: $0)
      }
    }
  }
}
