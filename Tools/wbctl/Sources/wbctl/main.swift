import Foundation
import WBCore
import WBDevices
import WBProcess

@main
struct WBCtl {
  static func main() async {
    let code = await WBCtl().run()
    if code != 0 {
      exit(code)
    }
  }

  private func run() async -> Int32 {
    var args = Array(CommandLine.arguments.dropFirst())
    let json = args.contains("--json")
    let fix = args.contains("--fix")
    args.removeAll { $0 == "--json" || $0 == "--fix" }
    guard let verb = args.first else {
      fputs(usage, stderr)
      return 2
    }
    switch verb {
    case "doctor":
      return await doctor(json: json, fix: fix)
    case "devices":
      return await devices(Array(args.dropFirst()), json: json)
    default:
      fputs(usage, stderr)
      return 2
    }
  }

  private func doctor(json: Bool, fix: Bool) async -> Int32 {
    let report = await Doctor.live().inspect()
    if json {
      emit(report.checks)
    } else {
      for check in report.checks {
        print("\(check.status.rawValue)\t\(check.name)\t\(check.summary)")
        if let fix = check.fix {
          print("\tfix\t\(fix)")
        }
      }
    }
    if fix {
      do {
        let directory = try AppPaths.ensure()
        if let url = try Doctor.writeFix(report, to: directory) {
          print("Wrote \(url.path)")
          print("Source it with: source \"\(url.path)\"")
        } else if !json {
          print("Nothing safe to fix.")
        }
      } catch {
        return fail(error, json: json)
      }
    }
    return report.hasFailures ? 1 : 0
  }

  private func devices(_ args: [String], json: Bool) async -> Int32 {
    guard let action = args.first else {
      fputs(usage, stderr)
      return 2
    }
    let services = makeServices()
    switch action {
    case "list":
      let inventory = await services.manager.inventory()
      if json {
        emit(inventory.devices)
        emit(inventory.problems.map { ErrorLine(error: $0) })
      } else {
        if inventory.devices.isEmpty {
          print("No devices.")
        }
        for device in inventory.devices {
          let serial = device.serial ?? "-"
          print(
            "\(device.id)\t\(device.name)\t\(device.state.rawValue)\t\(serial)\t\(device.detail)")
        }
        for problem in inventory.problems {
          fputs("\(problem.message)\n", stderr)
        }
      }
      return inventory.problems.isEmpty ? 0 : 1
    case "boot":
      guard let id = flag("--id", in: args) else {
        fputs("devices boot needs --id.\n", stderr)
        return 2
      }
      do {
        if json {
          emit([EventLine(event: "boot", id: id, state: "booting")])
        } else {
          print("Booting \(id)…")
        }
        let device = try await services.manager.boot(id: id)
        if json {
          emit([device])
        } else {
          print("\(device.id) is \(device.state.rawValue). \(device.detail)")
        }
        return 0
      } catch {
        return fail(error, json: json)
      }
    case "stop":
      guard let id = flag("--id", in: args) else {
        fputs("devices stop needs --id.\n", stderr)
        return 2
      }
      do {
        try await services.manager.stop(id: id)
        if json {
          emit([EventLine(event: "stop", id: id, state: "shutdown")])
        } else {
          print("Stopped \(id).")
        }
        return 0
      } catch {
        return fail(error, json: json)
      }
    default:
      fputs(usage, stderr)
      return 2
    }
  }

  private func makeServices() -> (manager: DeviceManager, supervisor: Supervisor) {
    let environment = ProcessInfo.processInfo.environment
    let home = FileManager.default.homeDirectoryForCurrentUser
    let support = (try? AppPaths.ensure(home: home)) ?? AppPaths.supportDirectory(home: home)
    _ = OrphanReaper.reap(directory: support.appendingPathComponent("pids"))
    let supervisor = Supervisor(directory: support)
    let locator = SystemToolLocator()
    let runner = SystemCommandRunner()
    let curl =
      locator.find(
        named: "curl",
        path: environment["PATH"] ?? "",
        extraDirectories: KnownTools.extraDirectories(for: "curl", home: home)
      )?.url ?? URL(fileURLWithPath: "/usr/bin/curl")
    let manager = DeviceManager(
      supervisor: supervisor,
      locator: locator,
      runner: runner,
      status: CurlEmulatorStatus(curl: curl, runner: runner),
      home: home,
      environment: environment,
      supportDirectory: support
    )
    return (manager, supervisor)
  }

  private func flag(_ name: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: name) else { return nil }
    let next = args.index(after: index)
    guard next < args.endIndex else { return nil }
    return args[next]
  }

  private func emit<T: Encodable>(_ values: [T]) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    for value in values {
      guard let data = try? encoder.encode(value) else { continue }
      print(String(decoding: data, as: UTF8.self))
    }
  }

  private func fail(_ error: Error, json: Bool) -> Int32 {
    let wrapped = error as? WBError
    let line = ErrorLine(
      error: wrapped?.message ?? error.localizedDescription,
      suggestion: wrapped?.suggestion
    )
    if json {
      emit([line])
    } else {
      fputs(line.error + "\n", stderr)
      if let suggestion = line.suggestion, !suggestion.isEmpty {
        fputs(suggestion + "\n", stderr)
      }
    }
    return 1
  }

  private var usage: String {
    """
    wbctl doctor [--json] [--fix]
    wbctl devices list [--json]
    wbctl devices boot --id <android:NAME|ios:UDID> [--json]
    wbctl devices stop --id <android:NAME|ios:UDID> [--json]

    """
  }
}

private struct EventLine: Encodable {
  var event: String
  var id: String
  var state: String
}

private struct ErrorLine: Encodable {
  var error: String
  var suggestion: String?

  init(error: WBError) {
    self.error = error.message
    self.suggestion = error.suggestion
  }

  init(error: String, suggestion: String?) {
    self.error = error
    self.suggestion = suggestion
  }
}
