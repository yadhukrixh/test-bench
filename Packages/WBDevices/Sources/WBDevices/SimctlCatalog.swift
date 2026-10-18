import Foundation

enum SimctlCatalog {
  static func devices(from data: Data) throws -> [Device] {
    let list = try JSONDecoder().decode(List.self, from: data)
    var devices: [Device] = []
    for (runtime, entries) in list.devices {
      for entry in entries where entry.isAvailable != false {
        let state: DeviceState
        switch entry.state {
        case "Booted":
          state = .booted
        case "Booting":
          state = .booting
        default:
          state = .shutdown
        }
        devices.append(
          Device(
            id: "ios:\(entry.udid)",
            platform: .ios,
            name: entry.name,
            state: state,
            serial: entry.udid,
            detail: runtime
          )
        )
      }
    }
    return devices.sorted { $0.name < $1.name }
  }
}

private struct List: Decodable {
  var devices: [String: [Entry]]
}

private struct Entry: Decodable {
  var udid: String
  var name: String
  var state: String
  var isAvailable: Bool?
}
