import AppKit
import SwiftUI
import WBCore
import WBDevices
import WBInspect
import WBMirror
import WBNetwork
import WBProcess
import WBSnapshot
import WBVision

struct WorkbenchView: View {
  @Bindable var model: AppModel
  @State private var rightTab = RightTab.device
  @State private var networkDetailTab = NetworkDetailTab.headers

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      if model.checks.contains(where: { $0.status == .fail }) {
        failureBanner
      }
      HSplitView {
        leftDock
        center
        rightDock
      }
    }
    .frame(minWidth: 960, minHeight: 640)
    .background(Color(nsColor: .windowBackgroundColor))
    .background { TranslationHost(broker: model.translationBroker) }
    .onCopyCommand {
      let text = model.selectedTextRun?.translation ?? model.selectedTextRun?.text ?? ""
      return text.isEmpty ? [] : [NSItemProvider(object: text as NSString)]
    }
    .sheet(isPresented: $model.needsAuthorization) {
      authorization
    }
    .sheet(isPresented: $model.showDoctor) {
      doctorSheet
    }
    .task {
      await model.start()
    }
  }

  private var toolbar: some View {
    HStack(spacing: 12) {
      Picker("Device", selection: $model.selection) {
        Text("No device").tag(String?.none)
        ForEach(model.devices) { device in
          Text("\(device.name) · \(device.state.rawValue)").tag(Optional(device.id))
        }
      }
      .pickerStyle(.menu)
      .frame(maxWidth: 280)
      .accessibilityLabel("Device")

      Button("Boot") { Task { await model.bootSelected() } }
        .disabled(model.busy || model.selection == nil || model.selectedDevice?.state == .booted)
        .accessibilityLabel("Boot")
      Button("Stop") { Task { await model.stopSelected() } }
        .disabled(model.busy || model.selectedDevice?.state == .shutdown || model.selection == nil)
        .accessibilityLabel("Stop")
      Button("Doctor") { model.showDoctor = true }
        .accessibilityLabel("Doctor")
      Toggle("Inspect", isOn: $model.inspectMode)
        .toggleStyle(.switch)
        .disabled(model.tree == nil)
        .accessibilityLabel("Inspect")
      Toggle("Text", isOn: $model.textMode)
        .toggleStyle(.switch)
        .disabled(model.frame == nil)
        .onChange(of: model.textMode) { _, _ in model.textDisplayChanged() }
        .accessibilityLabel("Text")
      Toggle("Translate", isOn: $model.translateMode)
        .toggleStyle(.switch)
        .disabled(model.frame == nil)
        .onChange(of: model.translateMode) { _, _ in model.textDisplayChanged() }
        .accessibilityLabel("Translate")
      Spacer()
      if model.busy {
        ProgressView().controlSize(.small)
      }
      Text(model.statusText)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
    .padding(12)
  }

  private var failureBanner: some View {
    HStack {
      Text("The doctor found a missing tool. Booting a device may fail until it is installed.")
      Spacer()
      Button("Copy fixes") { model.copyFixes() }
      Button("Details") { model.showDoctor = true }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color(nsColor: .systemYellow).opacity(0.35))
  }

  private var leftDock: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Tree").font(.headline)
        Spacer()
        Button("Refresh") { Task { await model.refreshTree() } }
          .disabled(model.dumping || !model.canDumpTree)
          .accessibilityLabel("Refresh tree")
      }
      if model.dumping {
        ProgressView().controlSize(.small)
      }
      if !model.treeMessage.isEmpty {
        Text(model.treeMessage)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      if let tree = model.tree {
        ScrollView {
          NodeRow(node: tree, selection: model.selectedNodeID) { id in
            model.selectNode(id: id)
          }
        }
      } else if model.treeMessage.isEmpty {
        empty("Boot an Android emulator to dump the hierarchy.")
      }
      HStack {
        Text("Snapshots").font(.headline)
        Spacer()
        Button("Capture") { Task { await model.captureSnapshot() } }
          .disabled(model.frame == nil || model.capturingSnapshot)
          .accessibilityLabel("Capture snapshot")
      }
      if model.snapshots.isEmpty {
        empty("Boot a device and capture a PNG plus the Android dump.")
      } else {
        if let selected = model.selectedSnapshot, let image = NSImage(contentsOf: selected.pngURL) {
          Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxHeight: 88)
            .accessibilityLabel("Selected snapshot")
        }
        ScrollView {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(model.snapshots) { snapshot in
              Button {
                model.selectedSnapshotID = snapshot.id
              } label: {
                Text(snapshot.id)
                  .font(.caption)
                  .foregroundStyle(
                    snapshot.id == model.selectedSnapshotID ? Color.primary : Color.secondary)
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Snapshot \(snapshot.id)")
            }
          }
        }
        .frame(maxHeight: 120)
      }
      Spacer()
    }
    .padding(16)
    .frame(minWidth: 220, maxWidth: 320, maxHeight: .infinity)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  private var center: some View {
    VStack(spacing: 12) {
      ZStack {
        RoundedRectangle(cornerRadius: 36)
          .stroke(Color.secondary.opacity(0.45), lineWidth: 2)
        if let frame = model.frame, let image = FrameImage.cgImage(from: frame) {
          DevicePicture(
            image: image,
            frame: frame,
            touchEnabled: model.canTouch || model.inspectMode || model.textMode
              || model.translateMode,
            highlight: model.selectedNode?.bounds,
            textRuns: (model.textMode || model.translateMode) ? model.textRuns : [],
            selectedTextID: model.selectedTextID,
            showTranslation: model.translateMode
          ) { x, y, pressure in
            model.touch(x: x, y: y, pressure: pressure)
          }
          .padding(14)
        } else {
          VStack(spacing: 8) {
            if model.selectedDevice?.state == .booted || model.selectedDevice?.state == .booting {
              ProgressView()
            } else {
              Image(systemName: "iphone")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            }
            Text(centerTitle)
              .font(.headline)
              .multilineTextAlignment(.center)
            Text(centerDetail)
              .font(.callout)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
          }
          .padding(24)
        }
      }
      .frame(maxWidth: 420, maxHeight: .infinity)
      .accessibilityLabel("Device frame")
      if model.canTouch {
        HStack(spacing: 12) {
          Button("Back") { model.sendKey("GoBack") }
            .accessibilityLabel("Back")
          Button("Home") { model.sendKey("GoHome") }
            .accessibilityLabel("Home")
          Button("Vol −") { model.sendKey("AudioVolumeDown") }
            .accessibilityLabel("Volume down")
          Button("Vol +") { model.sendKey("AudioVolumeUp") }
            .accessibilityLabel("Volume up")
          Button("Rotate") { Task { await model.rotateDevice() } }
            .accessibilityLabel("Rotate")
        }
        HStack(spacing: 8) {
          TextField("Clipboard", text: $model.clipboardText)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Clipboard")
          Button("Get") { Task { await model.readClipboard() } }
            .accessibilityLabel("Get clipboard")
          Button("Set") { Task { await model.writeClipboard() } }
            .accessibilityLabel("Set clipboard")
        }
        .frame(maxWidth: 420)
      } else if model.selectedDevice?.platform == .ios, model.selectedDevice?.state == .booted {
        Text("Screenshots only. Taps are not available on the simulator.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      apkControls
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var centerDetail: String {
    if model.selectedDevice?.state == .booted {
      return "Waiting for a frame."
    }
    if model.selectedDevice?.state == .booting {
      return "The device is still booting."
    }
    return "Boot a device to see its screen."
  }

  private var apkControls: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Button("Install APK…") { model.chooseAPKFromPanel() }
          .disabled(!model.canInstallAPK)
          .accessibilityLabel("Install APK")
        TextField("https://example.com/app.apk", text: $model.apkLink)
          .textFieldStyle(.roundedBorder)
          .disabled(!model.canInstallAPK)
          .accessibilityLabel("APK address")
        Button("Download, install, and run") { Task { await model.downloadAPK() } }
          .disabled(
            !model.canInstallAPK || model.apkLink.trimmingCharacters(in: .whitespaces).isEmpty
          )
          .accessibilityLabel("Download, install, and run")
      }
      HStack(spacing: 8) {
        Picker("In Downloads", selection: $model.selectedMacDownload) {
          Text("No APK in Downloads").tag(String?.none)
          ForEach(model.macDownloadAPKs, id: \.path) { apk in
            Text(apk.lastPathComponent).tag(Optional(apk.path))
          }
        }
        .disabled(!model.canInstallAPK)
        .accessibilityLabel("APK in Downloads")
        Button("Refresh Downloads") { model.refreshMacDownloads() }
          .disabled(!model.canInstallAPK)
          .accessibilityLabel("Refresh Downloads APKs")
        Button("Install from Downloads") { Task { await model.installMacDownload() } }
          .disabled(!model.canInstallAPK || model.selectedMacDownload == nil)
          .accessibilityLabel("Install from Downloads")
      }
      HStack(spacing: 8) {
        Picker("On the emulator", selection: $model.selectedDevicePackage) {
          Text("No APK on the emulator").tag(String?.none)
          ForEach(model.devicePackages) { package in
            Text(package.path).tag(Optional(package.path))
          }
        }
        .disabled(!model.canInstallAPK)
        .accessibilityLabel("APK on the emulator")
        Button("Refresh list") { Task { await model.refreshDeviceAPKs() } }
          .disabled(!model.canInstallAPK)
          .accessibilityLabel("Refresh emulator APKs")
        Button("Install and run") { Task { await model.installDeviceAPK() } }
          .disabled(!model.canInstallAPK || model.selectedDevicePackage == nil)
          .accessibilityLabel("Install and run")
      }
      Text(
        "Downloads with curl, installs with adb, then opens the app. Use a direct http or https link to the .apk file, a file in Downloads, a file or folder on this Mac, or an APK already on the emulator. Files are up to 200 MB."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .frame(maxWidth: 640)
  }

  private var centerTitle: String {
    if let device = model.selectedDevice {
      return "\(device.name) is \(device.state.rawValue)."
    }
    return "No device selected."
  }

  private var rightDock: some View {
    VStack(alignment: .leading, spacing: 12) {
      Picker("Inspector", selection: $rightTab) {
        ForEach(RightTab.allCases) { tab in
          Text(tab.rawValue).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      Group {
        switch rightTab {
        case .properties:
          propertiesPanel
        case .network:
          networkPanel
        case .text:
          textPanel
        case .console:
          consolePanel
        case .device:
          devicePanel
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .padding(16)
    .frame(
      minWidth: rightTab == .network ? 520 : 280,
      maxWidth: rightTab == .network ? 720 : 360,
      maxHeight: .infinity
    )
    .background(Color(nsColor: .controlBackgroundColor))
  }

  private var networkPanel: some View {
    VStack(alignment: .leading, spacing: 8) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 0) {
          ForEach(NetworkFilter.allCases) { filter in
            Button(filter.rawValue) {
              model.networkFilter = filter
              model.applyNetworkFilter()
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(model.networkFilter == filter ? Color.primary : Color.secondary)
            .overlay(alignment: .bottom) {
              Rectangle()
                .fill(model.networkFilter == filter ? Color.accentColor : Color.clear)
                .frame(height: 2)
            }
            .accessibilityLabel("\(filter.rawValue) filter")
            .accessibilityAddTraits(model.networkFilter == filter ? .isSelected : [])
          }
        }
      }
      .accessibilityLabel("Network filter")
      TextField("Filter", text: $model.networkQuery)
        .textFieldStyle(.roundedBorder)
        .onChange(of: model.networkQuery) { _, _ in model.applyNetworkFilter() }
        .accessibilityLabel("Search network")
      HStack {
        Button(model.networkPaused ? "Resume" : "Pause") {
          Task { await model.toggleNetworkPause() }
        }
        .accessibilityLabel(model.networkPaused ? "Resume network" : "Pause network")
        Button("Clear") { Task { await model.clearNetwork() } }
          .accessibilityLabel("Clear network")
        Button("HAR…") { model.exportHAR() }
          .disabled(model.networkEvents.isEmpty)
          .accessibilityLabel("Export HAR")
        Spacer()
        Text("\(model.networkEvents.count)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if !model.networkMessage.isEmpty {
        Text(model.networkMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      networkList
      networkDetail
    }
  }

  private var networkList: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Text("Name").frame(maxWidth: .infinity, alignment: .leading)
        Text("Status").frame(width: 48, alignment: .leading)
        Text("Method").frame(width: 64, alignment: .leading)
        Text("Type").frame(width: 52, alignment: .leading)
        Text("Size").frame(width: 52, alignment: .trailing)
        Text("Time").frame(width: 52, alignment: .trailing)
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 4)
      .padding(.bottom, 4)
      ScrollView {
        if model.networkEvents.isEmpty {
          empty(networkEmptyText)
            .padding(.top, 8)
        } else {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(model.networkEvents) { event in
              Button {
                model.selectNetwork(id: event.id)
              } label: {
                VStack(alignment: .leading, spacing: 2) {
                  HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                      Text(event.chromeName)
                      Text(event.host)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(event.statusLabel)
                      .foregroundStyle(statusColor(event))
                      .frame(width: 48, alignment: .leading)
                    Text(event.method)
                      .frame(width: 64, alignment: .leading)
                    Text(event.resourceType.rawValue)
                      .frame(width: 52, alignment: .leading)
                    Text(event.sizeLabel)
                      .frame(width: 52, alignment: .trailing)
                    Text(event.timeLabel)
                      .frame(width: 52, alignment: .trailing)
                  }
                  waterfall(event)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 2)
                }
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .padding(.vertical, 3)
                .padding(.horizontal, 4)
                .background(
                  event.id == model.selectedNetworkID
                    ? Color.accentColor.opacity(0.25) : Color.clear
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))
              }
              .buttonStyle(.plain)
              .accessibilityLabel("\(event.statusLabel) \(event.method) \(event.url)")
            }
          }
        }
      }
    }
    .frame(minHeight: 160)
  }

  private var networkDetail: some View {
    Group {
      if let event = model.selectedNetworkEvent {
        VStack(alignment: .leading, spacing: 8) {
          Picker("Detail", selection: $networkDetailTab) {
            ForEach(NetworkDetailTab.allCases) { tab in
              Text(tab.rawValue).tag(tab)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .accessibilityLabel("Network detail")
          ScrollView {
            switch networkDetailTab {
            case .headers:
              VStack(alignment: .leading, spacing: 8) {
                Text("General").font(.caption).bold()
                labeled("Request URL", event.url)
                labeled("Request Method", event.method)
                labeled("Status Code", event.statusLabel)
                labeled("Remote Address", event.host)
                labeled("Type", event.resourceType.rawValue)
                labeled("Source", event.sources.map(\.rawValue).joined(separator: ", "))
                if event.method.uppercased() == "CONNECT" || event.method.uppercased() == "DNS" {
                  Text(
                    "This is the TLS or DNS session for the host. HTTPS is passed through so the app keeps internet. Page fetches reuse this socket, so they do not appear as extra CONNECT rows. Attach a debug or profile Flutter build for each API path and body."
                  )
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
                }
                if let error = event.error, !error.isEmpty {
                  labeled("Error", error)
                }
                Text("Request Headers").font(.caption).bold()
                Text(headerText(HeaderRedaction.mask(event.requestHeaders)))
                  .font(.system(.caption, design: .monospaced))
                  .textSelection(.enabled)
                Text("Response Headers").font(.caption).bold()
                Text(headerText(HeaderRedaction.mask(event.responseHeaders)))
                  .font(.system(.caption, design: .monospaced))
                  .textSelection(.enabled)
              }
            case .payload:
              bodyBlock("Request payload", model.selectedNetworkBodies?.request ?? Data())
            case .preview:
              bodyBlock("Preview", model.selectedNetworkBodies?.response ?? Data())
            case .response:
              bodyBlock("Response", model.selectedNetworkBodies?.response ?? Data())
            case .timing:
              VStack(alignment: .leading, spacing: 8) {
                labeled("Time", event.timeLabel)
                labeled("Size", event.sizeLabel)
                if event.events.isEmpty {
                  Text("No timing marks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                  ForEach(Array(event.events.enumerated()), id: \.offset) { _, mark in
                    labeled(mark.event, "\(mark.timestamp) µs")
                  }
                }
              }
            }
          }
          HStack {
            Button("Copy URL") { model.copyNetworkURL() }
            Button("Copy cURL") { model.copyNetworkCurl() }
            Button("Copy response") { model.copyNetworkResponse() }
          }
        }
      } else {
        empty("No request selected.")
      }
    }
  }

  private var networkEmptyText: String {
    if model.networkFilter == .fetch {
      if model.httpsIntercept {
        return
          "No Fetch/XHR yet. Navigate in the release app so API calls flow through VPN + SOCKS intercept."
      }
      return
        "No Fetch/XHR yet. HTTPS APIs on a release Flutter app share one TLS row (CONNECT) until release intercept or a debug/profile attach is active."
    }
    if model.flutterRunning {
      return "No HTTP yet. Use the app so dart:io or proxied requests appear."
    }
    if model.proxyRunning {
      if model.httpsIntercept {
        return
          "No HTTP yet. Use the app on the emulator. With release intercept, rows should show full URLs and JSON bodies, not CONNECT-only hosts."
      }
      return
        "No HTTP yet. Open a page on the emulator. A CONNECT row is the TLS host, not each API. Enable release intercept or attach a debug/profile APK for paths and bodies."
    }
    return "No HTTP. Run or Attach a debug Flutter app, or boot Android so capture can start."
  }

  private var waterfallMax: Int {
    max(model.networkEvents.compactMap(\.durationMillis).max() ?? 1, 1)
  }

  private func waterfall(_ event: NetworkEvent) -> some View {
    let duration = event.durationMillis ?? 0
    let fraction = min(
      max(Double(duration) / Double(waterfallMax), duration == 0 ? 0.04 : 0.08), 1)
    return GeometryReader { geo in
      RoundedRectangle(cornerRadius: 2)
        .fill(statusColor(event).opacity(0.65))
        .frame(width: max(geo.size.width * fraction, 4), height: 6)
    }
    .frame(height: 6)
  }

  private func statusColor(_ event: NetworkEvent) -> Color {
    if event.state == .failed { return .red }
    guard let status = event.status else { return .secondary }
    if event.method.uppercased() == "CONNECT" { return .secondary }
    if (200..<300).contains(status) { return .green }
    if (300..<400).contains(status) { return .orange }
    if status >= 400 { return .red }
    return .secondary
  }

  private var textPanel: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker("Target", selection: $model.targetLanguage) {
        Text("English").tag("en")
        Text("Japanese").tag("ja")
      }
      .onChange(of: model.targetLanguage) { _, _ in model.textDisplayChanged() }
      .accessibilityLabel("Target language")
      Text("On-device translation. Screen text stays on this Mac.")
        .font(.caption)
        .foregroundStyle(.secondary)
      if !model.translationMessage.isEmpty {
        Text(model.translationMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      Button("Copy") { model.copySelectedText() }
        .disabled(model.selectedTextRun == nil)
        .accessibilityLabel("Copy text")
      ScrollView {
        if model.textRuns.isEmpty {
          empty(
            model.textMode || model.translateMode
              ? "Waiting for OCR after the screen settles."
              : "Turn on Text or Translate to read the screen."
          )
        } else {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(model.textRuns) { run in
              Button {
                model.selectedTextID = run.id
              } label: {
                VStack(alignment: .leading, spacing: 2) {
                  Text(run.text)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                  if let translation = run.translation, !translation.isEmpty {
                    Text(translation)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(3)
                  }
                  Text(run.origin.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                .padding(4)
                .background(
                  run.id == model.selectedTextID
                    ? Color.accentColor.opacity(0.25) : Color.clear
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))
              }
              .buttonStyle(.plain)
              .accessibilityLabel(run.text)
            }
          }
        }
      }
    }
  }

  private var propertiesPanel: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        if let node = model.selectedNode {
          labeled("Class", node.className)
          labeled("Package", node.package)
          labeled("Resource id", node.resourceId)
          labeled("Text", node.text)
          labeled("Content description", node.contentDescription)
          labeled(
            "Bounds",
            "[\(node.bounds.left),\(node.bounds.top)][\(node.bounds.right),\(node.bounds.bottom)]"
          )
          labeled("Clickable", node.clickable ? "true" : "false")
          labeled("Enabled", node.enabled ? "true" : "false")
          labeled("Focusable", node.focusable ? "true" : "false")
          labeled("Focused", node.focused ? "true" : "false")
          labeled("Checkable", node.checkable ? "true" : "false")
          labeled("Checked", node.checked ? "true" : "false")
          labeled("Selected", node.selected ? "true" : "false")
          labeled("Scrollable", node.scrollable ? "true" : "false")
        } else if model.tree != nil {
          empty("Select a node in the tree, or turn on Inspect and click the picture.")
        } else {
          empty("The hierarchy is not available yet.")
        }
      }
    }
  }

  private var devicePanel: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let device = model.selectedDevice {
        labeled("Name", device.name)
        labeled("Id", device.id)
        labeled("State", device.state.rawValue)
        labeled("Detail", device.detail)
      } else {
        empty("No device selected.")
      }
      if !model.problems.isEmpty {
        Text(model.problems.joined(separator: "\n"))
          .font(.callout)
          .foregroundStyle(.red)
      }
      Divider()
      Text("Flutter").font(.headline)
      Text(model.flutterProject?.path ?? "No project selected.")
        .font(.callout)
        .textSelection(.enabled)
      HStack {
        Button("Choose project…") { model.chooseFlutterProjectFromPanel() }
          .disabled(model.busy)
          .accessibilityLabel("Choose Flutter project")
        Button("Run") { Task { await model.runFlutter() } }
          .disabled(!model.canRunFlutter)
          .accessibilityLabel("Run Flutter")
        Button("Attach") { Task { await model.attachFlutter() } }
          .disabled(!model.canAttachFlutter)
          .accessibilityLabel("Attach Flutter")
      }
      HStack {
        Button("Hot reload") { Task { await model.reloadFlutter(full: false) } }
          .disabled(!model.flutterRunning || model.busy)
          .accessibilityLabel("Hot reload")
        Button("Hot restart") { Task { await model.reloadFlutter(full: true) } }
          .disabled(!model.flutterRunning || model.busy)
          .accessibilityLabel("Hot restart")
        Button("Stop Flutter") { Task { await model.stopFlutter() } }
          .disabled(!model.flutterRunning)
          .accessibilityLabel("Stop Flutter")
      }
      Text(
        "Run starts flutter run --machine. Attach uses flutter attach --machine on an installed debug or profile APK. Release builds have no VM service. Booting Android starts mitmdump and sets http_proxy to \(ProxyFlow.guestAddress). HTTPS is passed through so the app keeps internet."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var consolePanel: some View {
    ScrollView {
      if model.flutterLog.isEmpty {
        empty("Flutter machine output appears here after Run or Attach.")
      } else {
        Text(model.flutterLog.joined(separator: "\n"))
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var authorization: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Before you use QA Workbench").font(.title2)
      Text(
        "This app starts emulators and simulators on this Mac and can control what they display. Use it only on apps and devices you are allowed to test."
      )
      .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("I understand") { model.acknowledge() }
          .keyboardShortcut(.defaultAction)
          .accessibilityLabel("I understand")
      }
    }
    .padding(24)
    .frame(width: 440)
  }

  private var doctorSheet: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Doctor").font(.title2)
      List(model.checks, id: \.name) { check in
        VStack(alignment: .leading, spacing: 4) {
          Text("\(check.status.rawValue) · \(check.name)").font(.headline)
          Text(check.summary).font(.callout)
          if let fix = check.fix {
            Text(fix)
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
          }
        }
        .padding(.vertical, 4)
      }
      HStack {
        Button("Copy fixes") { model.copyFixes() }
        Spacer()
        Button("Close") { model.showDoctor = false }
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .frame(width: 640, height: 480)
  }

  private func empty(_ text: String) -> some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func headerText(_ headers: [String: [String]]) -> String {
    if headers.isEmpty { return "(none)" }
    return headers.keys.sorted().map { key in
      "\(key): \((headers[key] ?? []).joined(separator: ", "))"
    }.joined(separator: "\n")
  }

  private func bodyBlock(_ title: String, _ data: Data) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      if data.isEmpty {
        Text("(empty)").font(.caption).foregroundStyle(.secondary)
      } else if let text = prettyBody(data) {
        Text(text)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
      } else {
        Text(data.prefix(256).map { String(format: "%02x", $0) }.joined(separator: " "))
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
      }
    }
  }

  private func prettyBody(_ data: Data) -> String? {
    if let object = try? JSONSerialization.jsonObject(with: data),
      let pretty = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
      let text = String(data: pretty, encoding: .utf8)
    {
      return text
    }
    return String(data: data, encoding: .utf8)
  }

  private func labeled(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value).textSelection(.enabled)
    }
  }
}

private enum NetworkDetailTab: String, CaseIterable, Identifiable {
  case headers = "Headers"
  case payload = "Payload"
  case preview = "Preview"
  case response = "Response"
  case timing = "Timing"

  var id: String { rawValue }
}

private enum RightTab: String, CaseIterable, Identifiable {
  case properties = "Properties"
  case network = "Network"
  case text = "Text"
  case console = "Console"
  case device = "Device"

  var id: String { rawValue }
}

private struct NodeRow: View {
  var node: Node
  var selection: String?
  var onSelect: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Button {
        onSelect(node.id)
      } label: {
        Text(node.label)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 2)
          .padding(.horizontal, 4)
          .background(node.id == selection ? Color.accentColor.opacity(0.25) : Color.clear)
          .clipShape(RoundedRectangle(cornerRadius: 4))
      }
      .buttonStyle(.plain)
      .accessibilityLabel(node.label)
      if !node.children.isEmpty {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(node.children) { child in
            NodeRow(node: child, selection: selection, onSelect: onSelect)
          }
        }
        .padding(.leading, 12)
      }
    }
  }
}

private struct DevicePicture: View {
  var image: CGImage
  var frame: DeviceFrame
  var touchEnabled: Bool
  var highlight: NodeBounds?
  var textRuns: [TextRun] = []
  var selectedTextID: String?
  var showTranslation = false
  var onTouch: (Int, Int, Int) -> Void

  var body: some View {
    GeometryReader { geo in
      let fitted = fittedSize(in: geo.size)
      ZStack {
        Image(decorative: image, scale: 1, orientation: .up)
          .resizable()
          .frame(width: fitted.width, height: fitted.height)
        ForEach(textRuns) { run in
          if let rect = viewRect(run.bounds, fitted: fitted) {
            ZStack {
              RoundedRectangle(cornerRadius: 3)
                .fill(Color.black.opacity(showTranslation && run.translation != nil ? 0.55 : 0.12))
              RoundedRectangle(cornerRadius: 3)
                .stroke(
                  run.id == selectedTextID ? Color.accentColor : Color.yellow.opacity(0.8),
                  lineWidth: run.id == selectedTextID ? 2 : 1
                )
              if showTranslation, let translation = run.translation, !translation.isEmpty {
                Text(translation)
                  .font(.system(size: max(min(rect.height * 0.6, 16), 8)))
                  .foregroundStyle(.white)
                  .lineLimit(2)
                  .minimumScaleFactor(0.4)
                  .padding(2)
              }
            }
            .frame(width: max(rect.width, 1), height: max(rect.height, 1))
            .position(x: rect.midX, y: rect.midY)
          }
        }
        if let highlight, let rect = viewRect(highlight, fitted: fitted) {
          Rectangle()
            .stroke(Color.accentColor, lineWidth: 2)
            .frame(width: max(rect.width, 1), height: max(rect.height, 1))
            .position(x: rect.midX, y: rect.midY)
        }
      }
      .frame(width: fitted.width, height: fitted.height)
      .gesture(drag(fitted))
      .position(x: geo.size.width / 2, y: geo.size.height / 2)
    }
  }

  private func viewRect(_ bounds: NodeBounds, fitted: CGSize) -> CGRect? {
    let geometry = DeviceGeometry(
      deviceWidth: Double(frame.deviceWidth),
      deviceHeight: Double(frame.deviceHeight),
      viewWidth: fitted.width,
      viewHeight: fitted.height
    )
    guard
      let origin = geometry.viewPoint(deviceX: Double(bounds.left), deviceY: Double(bounds.top)),
      let corner = geometry.viewPoint(deviceX: Double(bounds.right), deviceY: Double(bounds.bottom))
    else { return nil }
    return CGRect(
      x: origin.x,
      y: origin.y,
      width: corner.x - origin.x,
      height: corner.y - origin.y
    )
  }

  private func drag(_ fitted: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        guard touchEnabled, let point = devicePoint(value.location, fitted: fitted) else { return }
        onTouch(point.x, point.y, 1)
      }
      .onEnded { value in
        guard touchEnabled, let point = devicePoint(value.location, fitted: fitted) else { return }
        onTouch(point.x, point.y, 0)
      }
  }

  private func devicePoint(_ location: CGPoint, fitted: CGSize) -> (x: Int, y: Int)? {
    guard fitted.width > 0, fitted.height > 0 else { return nil }
    guard location.x >= 0, location.y >= 0, location.x <= fitted.width, location.y <= fitted.height
    else {
      return nil
    }
    let geometry = DeviceGeometry(
      deviceWidth: Double(frame.deviceWidth),
      deviceHeight: Double(frame.deviceHeight),
      viewWidth: fitted.width,
      viewHeight: fitted.height
    )
    guard let point = geometry.devicePoint(viewX: location.x, viewY: location.y) else { return nil }
    let x = min(max(Int(point.x.rounded()), 0), max(frame.deviceWidth - 1, 0))
    let y = min(max(Int(point.y.rounded()), 0), max(frame.deviceHeight - 1, 0))
    return (x, y)
  }

  private func fittedSize(in container: CGSize) -> CGSize {
    let imageWidth = CGFloat(frame.imageWidth)
    let imageHeight = CGFloat(frame.imageHeight)
    guard imageWidth > 0, imageHeight > 0, container.width > 0, container.height > 0 else {
      return container
    }
    let scale = min(container.width / imageWidth, container.height / imageHeight)
    return CGSize(width: imageWidth * scale, height: imageHeight * scale)
  }
}
