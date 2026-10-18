# QA Workbench

A native macOS application for automated testing of Android and iOS applications. QA Workbench provides device control, live screen mirroring, network inspection, Flutter integration, and computer vision capabilities for quality assurance workflows.

## Project Philosophy

QA Workbench was built to solve a common problem in mobile development: the fragmentation of testing tools across multiple command-line interfaces, IDEs, and platforms. Instead of switching between Android Studio, Xcode, adb commands, Flutter tools, network sniffers, and screenshot utilities, QA Workbench unifies these capabilities into a single, cohesive interface.

**Core Principles:**

1. **Unified Interface**: One tool for device control, screen viewing, network inspection, and automated testing
2. **Native Performance**: Swift 6 with direct system framework access for maximum performance and reliability
3. **Minimal Dependencies**: Zero third-party Swift packages reduces attack surface and maintenance burden
4. **Protocol-Based Design**: Clean abstractions enable testing and future extensibility
5. **Developer-Focused**: Built by developers, for developers, with real workflows in mind
6. **Privacy-Respecting**: All data stays local; no cloud services or telemetry

**Why Native Swift?**

After Phase 0 research (see [SPIKES.md](docs/SPIKES.md)), native Swift was chosen over alternatives like Tauri+React because:
- ScreenCaptureKit, Vision, and Translation require AppKit/SwiftUI hosts anyway
- Direct framework access provides better performance and fewer compatibility issues
- Swift 6 concurrency model simplifies async operations
- Single-process architecture reduces complexity
- No JavaScript layer means one less technology to maintain

## Target Audience

QA Workbench is designed for professionals who need to test mobile applications efficiently:

**Primary Users:**
- QA Engineers who need to verify app behavior across devices and configurations
- Mobile Developers who want rapid iteration with hot reload and network debugging
- Automation Testers building and maintaining test suites
- DevOps Engineers integrating mobile testing into CI/CD pipelines

**Scenarios:**
- **Regression Testing**: Capture screenshots at key points, compare with baselines
- **Network Debugging**: Inspect API calls, headers, and payloads across all HTTP clients
- **Localization Testing**: Use OCR and translation to verify UI text in multiple languages
- **Accessibility Testing**: Inspect UI hierarchies to verify proper labeling and structure
- **Performance Testing**: Monitor network patterns and identify slow endpoints
- **Flutter Development**: Hot reload workflows without leaving the testing environment

## Overview

QA Workbench (Phase 7) is a native macOS app written in Swift 6 that enables comprehensive mobile app testing through a single interface. It unifies device control, screen monitoring, network inspection, and automated testing workflows into one tool, eliminating the need to juggle multiple command-line tools and IDEs.

### Key Capabilities

- **Device Management**: Boot and stop Android emulators and iOS simulators with automatic cleanup of orphaned processes
- **Live Mirroring**: Display real-time device screens with interactive controls, supporting scaled frames for performance and full-resolution captures for detail
- **UI Inspection**: Dump and analyze Android UI hierarchies using UiAutomator, with hit testing to identify nodes at any screen position
- **Snapshots**: Capture PNG images plus XML dumps for documentation, regression testing, and analysis
- **Flutter Integration**: Run Flutter projects with hot reload/restart on a pseudo-terminal, or attach to installed debug/profile builds for production APK testing
- **Network Monitoring**: Inspect HTTP traffic from multiple sources simultaneously:
  - Dart VM HTTP profile (dart:io, package:http, dio)
  - Emulator HTTP proxy (native clients that honor http_proxy)
  - On-device packet capture (DNS queries and TLS SNI for all apps)
- **Computer Vision**: Perform OCR and on-screen text translation using Apple's Vision framework, with multi-language support including Japanese
- **Device Control**: Tap, press Back/Home, change volume, rotate screen, and manage clipboard on Android through gRPC and adb
- **APK Management**: Install APKs from local files, HTTP/HTTPS URLs, or directly from the emulator's storage

### Use Cases

**For QA Engineers:**
- Visual regression testing with side-by-side screen comparison
- Automated screenshot capture for documentation
- Network traffic inspection for API debugging
- UI element location and verification without modifying app code
- Translation testing for internationalized apps

**For Mobile Developers:**
- Rapid Flutter development with hot reload without leaving the workbench
- Debug network requests across multiple clients (VM, native, proxy)
- Test app behavior on different device configurations
- Inspect UI hierarchies for accessibility testing
- Capture and analyze app state at any point

**For Automation Testers:**
- Programmatic device control through wbctl CLI
- Snapshot capture for test evidence
- Network monitoring for performance analysis
- OCR-based verification for visual elements

## Architecture

### Technology Stack

- **Language**: Swift 6 (Swift 6 language mode)
- **Platform**: macOS 15+
- **UI Framework**: SwiftUI (app target only)
- **Dependencies**: Zero third-party Swift packages (uses only system frameworks)
- **Package Manager**: Swift Package Manager

### Modular Design

The project is organized into modular Swift packages, each with a specific responsibility:

| Package | Purpose |
| --- | --- |
| **WBCore** | Core utilities: clock, event bus, session state, error types, device geometry |
| **WBDevices** | Device management: list, boot, and stop Android AVDs and iOS simulators |
| **WBMirror** | Live device frames and touch input (Android gRPC, iOS simctl) |
| **WBInspect** | UI hierarchy inspection (UiAutomator XML parsing, node selection) |
| **WBFlutter** | Flutter integration: run/attach, hot reload/restart, VM service client |
| **WBNetwork** | Network monitoring: VM HTTP profile, HTTP proxy, packet capture, HAR export |
| **WBProcess** | Process management: command execution, pseudo-terminals, process supervision |
| **WBSnapshot** | Snapshot storage: PNG images with XML dumps |
| **WBVision** | Computer vision: OCR, text recognition, on-device translation |
| **WBWeb** | WebView inspection (Chrome DevTools Protocol - not yet implemented) |
| **WBTestSupport** | Testing utilities: manual clock, scripted command runner |

### Design Decisions

See Architecture Decision Records:
- [ADR 0001: Native Swift](docs/adr/0001-native-swift.md) - Why native Swift over alternatives
- [ADR 0002: App Sandbox Off](docs/adr/0002-app-sandbox-off.md) - Sandbox disabled for tool access

### Technical Implementation Details

**Android Integration:**
- Emulator communication via gRPC protocol (cleartext HTTP/2 through Network.framework)
- No third-party gRPC library - protobuf field numbers extracted from emulator proto
- UiAutomator hierarchy dumped via `adb exec-out uiautomator dump /dev/tty`
- Device control through gRPC `sendTouch`, `sendKey`, `setClipboard`, `getClipboard`
- Volume control via W3C AudioVolumeUp/AudioVolumeDown key codes
- Screen rotation via `adb shell wm user-rotation lock`
- APK installation via `adb install -r -t` with activity launch from `aapt dump badging`

**iOS Integration:**
- Simulator screenshots via `xcrun simctl io screenshot` (polling fallback)
- Device list from `xcrun simctl list devices available`
- Boot/shutdown via `xcrun simctl boot` and `xcrun simctl shutdown`
- Note: idb not installed, so advanced features unavailable

**Flutter Integration:**
- `flutter run --machine` executed on POSIX pseudo-terminal (required for debugPort)
- Machine protocol JSON events parsed for appId, wsUri, port, baseUri
- VM service client via URLSessionWebSocketTask speaking JSON-RPC 2.0
- HTTP profile monitoring via `ext.dart.io.getHttpProfile` polling
- Hot reload/restart via `app.restart` with appId, fullRestart, pause, debounce
- Automatic re-connection after hot restart (isolate id changes)

**Network Monitoring:**
- VM HTTP profile: captures dart:io, package:http, dio requests
- HTTP proxy: mitmdump on 127.0.0.1:18080, emulator http_proxy set to 10.0.2.2:18080
- Packet capture: PCAPdroid APK installed via adb, exports to 127.0.0.1:18081 via adb reverse
- TLS passthrough enabled (no HTTPS decryption) to maintain app connectivity
- HAR 1.2 export with _source field (vm/proxy/packet)
- Secret masking for Authorization, Cookie, Set-Cookie headers

**Computer Vision:**
- OCR via VNRecognizeTextRequest with multi-language support (en-US, ja-JP, 33 languages)
- Vision coordinate system flipped to device pixels
- IoU-based de-duplication against node text (threshold 0.5)
- On-device translation via SwiftUI .translationTask
- Language detection via NLLanguageRecognizer
- Translation cache to avoid repeated API calls

## Current Status

**Phase 7 is implemented and verified** (as of 2026-10-15)

### Completed Features

- ✅ PNG plus UiAutomator XML snapshots saved to Application Support
- ✅ Full-resolution Android frame capture when mirror is active
- ✅ Clipboard get/set through EmulatorController ClipData
- ✅ Volume up/down control via W3C AudioVolume keys
- ✅ Screen rotation via `adb shell wm user-rotation lock`
- ✅ TLS passthrough for HTTPS (emulator maintains internet access)
- ✅ Live device mirroring with scaled frames
- ✅ Android UI tree inspection with hit testing
- ✅ Flutter Run with `flutter run --machine` on pseudo-terminal
- ✅ Flutter Attach for installed debug/profile APKs
- ✅ Hot reload and hot restart support
- ✅ VM HTTP profile monitoring (dart:io, package:http, dio)
- ✅ HTTP proxy integration (mitmdump) for native clients
- ✅ On-device packet capture (PCAPdroid) for DNS and TLS SNI
- ✅ Network tab with filters, search, headers, and HAR 1.2 export
- ✅ Screen OCR with Vision framework (multi-language support)
- ✅ On-device translation with SwiftUI translationTask
- ✅ Text overlay with selectable boxes and copy support

### Known Limitations

- **iOS**: Limited to `simctl` screenshot polling (~1.8 fps). No live video, taps, volume, rotate, clipboard, or UI tree (idb not installed)
- **WebView**: Inspection not yet implemented (pending S8 spike)
- **Proxy**: Dart `HttpClient` ignores system HTTP proxy; packet capture lists DNS and TLS SNI only
- **HTTPS**: Passed through without decryption (Play image cannot install system CA)
- **Translation**: Languages may need download (uses on-device translation)
- **Git**: No commits or phase tags (git user.name/email not configured)

See [docs/STATUS.md](docs/STATUS.md) for detailed phase history and verification notes.

## Getting Started

### Prerequisites

- macOS 15 or later
- Xcode 26.3 or later
- Android SDK with emulator
- Flutter SDK (optional, for Flutter projects)
- Homebrew (for mitmproxy installation)

### Installation

From the repository root:

```bash
cd /Users/yadhu/Documents/qa-bench
scripts/bundle-app.sh
open "build/QA Workbench.app"
```

### First Launch

The first launch asks you to confirm that you will only test apps and devices you are allowed to test.

### Basic Usage

1. **Boot a Device**: Choose `Pixel_8` (or available AVD) and press Boot
2. **View Screen**: The phone frame shows the live device screen
3. **Inspect UI**: The left dock displays the UiAutomator tree
4. **Capture Snapshots**: Use Capture in the left dock to save PNG+XML
5. **Install APKs**: Install APK… picks local files, or download from URLs
6. **Flutter Integration**: Use Device tab to Run or Attach Flutter projects
7. **Network Monitoring**: View HTTP traffic in the Network tab
8. **OCR/Translation**: Enable Text or Translate in the toolbar

See [docs/HOW_TO_RUN.md](docs/HOW_TO_RUN.md) for detailed usage instructions.

## Command Line Tools

### wbctl

The `wbctl` command-line tool provides device management capabilities:

```bash
scripts/doctor  # Build wbctl and run diagnostics
Tools/wbctl/.build/debug/wbctl devices list
Tools/wbctl/.build/debug/wbctl devices boot --id android:Pixel_8
Tools/wbctl/.build/debug/wbctl devices stop --id android:Pixel_8
Tools/wbctl/.build/debug/wbctl devices boot --id ios:UDID
Tools/wbctl/.build/debug/wbctl devices stop --id ios:UDID
```

### Tests

Run the test suite:

```bash
scripts/test.sh
```

This runs unit tests and builds `wbctl` and the app with warnings treated as errors.

## Key Workflows

### Flutter Development Workflow

1. Select a booted Android emulator in the device menu
2. On the Device tab, click "Choose project…" and select your Flutter project directory
3. Click "Run" to start `flutter run --machine` on a pseudo-terminal
4. The Console shows machine events (app.start, app.debugPort, app.started)
5. Make code changes in your editor, then click "Hot reload" to apply without restart
6. For larger changes, click "Hot restart" to rebuild the app
7. Inspect network traffic in the Network tab (VM HTTP profile)
8. Use OCR/Translation to verify UI text without manual inspection
9. Click "Stop Flutter" to terminate the Flutter process

### Network Debugging Workflow

1. Boot an Android emulator
2. Install and run your app (or use Flutter Run/Attach)
3. Switch to the Network tab
4. Observe traffic from three sources:
   - **VM**: Dart HTTP clients (dart:io, package:http, dio) - shows full request/response
   - **Proxy**: Native HTTP clients that honor emulator proxy - shows headers and URL
   - **Packet**: All network activity (DNS, TLS SNI) - shows hostnames
5. Click any request to view headers, payload, and response
6. Use filters to narrow by method, status, or search text
7. Export to HAR 1.2 for analysis in other tools
8. Secrets are automatically masked in UI and exports

### UI Inspection Workflow

1. Boot an Android emulator and navigate to your app
2. Enable "Inspect" in the toolbar
3. Click anywhere on the live screen to select the smallest node at that position
4. The left dock shows the UiAutomator tree with the selected node highlighted
5. Properties panel displays all node attributes (class, package, resource-id, text, content-desc, bounds)
6. Use "Refresh" to get a fresh hierarchy dump
7. Tap on screen elements to trigger actions and see updated hierarchy
8. Capture snapshots with PNG+XML for documentation

### APK Testing Workflow

**From Local File:**
1. Click "Install APK…" and select an APK file on your Mac
2. The workbench installs via `adb install -r -t` and launches the app
3. Use the device controls to interact with the app
4. Monitor network traffic and capture snapshots

**From URL:**
1. Click "Download, install, and run"
2. Enter an http or https URL (max 200 MB)
3. The workbench downloads via curl, installs, and launches
4. Useful for testing release builds from CI/CD

**From Emulator:**
1. Click "On the emulator" to list APKs in common directories
2. Select an APK to copy off the device, install, and launch
3. Useful for testing APKs already present on the device

### Snapshot and Regression Workflow

1. Navigate your app to the desired state
2. Click "Capture" in the left dock
3. Snapshots are saved to Application Support with timestamp
4. Each snapshot includes:
   - Full-resolution PNG image
   - UiAutomator XML hierarchy dump
5. Use snapshots for:
   - Visual regression comparison
   - UI state documentation
   - Test evidence in bug reports
   - Automated test baselines

## Development Methodology

### Phased Development

QA Workbench follows a phased development approach, with each phase building on the previous:

- **Phase 0**: Research spikes to validate technical approaches (see [SPIKES.md](docs/SPIKES.md))
- **Phase 1**: Core infrastructure - packages, wbctl, device boot/stop, process supervision
- **Phase 2**: Live mirroring - Android gRPC frames, taps, iOS screenshots, APK installation
- **Phase 3**: UI inspection - UiAutomator tree, hit testing, node selection
- **Phase 4**: Flutter integration - run/attach, hot reload/restart, APK download
- **Phase 5**: Network monitoring - VM HTTP profile, HTTP proxy, packet capture, HAR export
- **Phase 6**: Computer vision - OCR, text recognition, on-device translation
- **Phase 7**: Device controls - volume, rotate, clipboard, full-resolution snapshots
- **Phase 8**: WebView inspection (planned, pending S8 spike)
- **Phase 9**: Distribution - Developer ID signing, disk image build (planned)

Each phase includes:
- Implementation of target features
- Unit tests with warnings as errors
- Demo documentation in docs/demos/
- Verification against spike findings

### Testing Strategy

**Unit Tests:**
- All packages include test targets
- Tests cover core logic, error handling, and edge cases
- Warnings treated as errors to maintain code quality
- No emulator or device booting in default test suite

**Integration Testing:**
- Manual testing via demo guides in docs/demos/
- Phase-specific verification documented in STATUS.md
- Real device/emulator testing for feature validation

**Code Quality:**
- Swift 6 language mode with strict concurrency
- `xcrun swift-format lint --recursive --strict` on all code
- Protocol-based design for testability
- Manual clock and scripted command runner for deterministic tests

## Documentation

- [HOW_TO_RUN.md](docs/HOW_TO_RUN.md) - Detailed setup and usage instructions
- [STATUS.md](docs/STATUS.md) - Implementation status and phase history
- [TODO.md](docs/TODO.md) - Outstanding items and future work
- [DEPENDENCIES.md](docs/DEPENDENCIES.md) - External dependencies and licenses
- [SPIKES.md](docs/SPIKES.md) - Phase 0 research findings and measurements
- [Demos](docs/demos/) - Phase-by-phase demo guides

## Project Structure

```
qa-bench/
├── App/                    # Main SwiftUI application
│   ├── Package.swift
│   └── Sources/QAWorkbench/
├── Packages/               # Swift packages
│   ├── WBCore/            # Core utilities
│   ├── WBDevices/         # Device management
│   ├── WBMirror/          # Screen mirroring
│   ├── WBInspect/         # UI inspection
│   ├── WBFlutter/         # Flutter integration
│   ├── WBNetwork/         # Network monitoring
│   ├── WBProcess/         # Process management
│   ├── WBSnapshot/        # Snapshot storage
│   ├── WBTestSupport/     # Testing utilities
│   ├── WBVision/          # Computer vision
│   └── WBWeb/             # WebView inspection
├── Tools/
│   └── wbctl/             # Command-line tool
├── Spikes/                # Phase 0 research probes
├── scripts/               # Build and test scripts
├── docs/                  # Documentation
└── README.md
```

## Development

### Adding Dependencies

The project intentionally avoids third-party Swift packages. All functionality is built using:
- System frameworks (Network.framework, Vision, Translation, etc.)
- Standard Swift library
- External tools invoked as child processes (adb, emulator, simctl, flutter)

See [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md) for detailed dependency information.

### Code Style

- Swift 6 language mode
- Warnings treated as errors
- `xcrun swift-format lint --recursive --strict` on Packages, Tools, and App

### Architecture Principles

- Protocol-based design for testability
- Process isolation for external tools
- No third-party Swift package dependencies
- SwiftUI only in app target
- Swift concurrency (async/await) throughout

## Future Roadmap

### Near-Term (Phase 8-9)

- **Phase 8**: WebView inspection via Chrome DevTools Protocol
- **Phase 9**: Distribution - Developer ID signing, disk image build, notarization

### Medium-Term

- iOS live video via ScreenCaptureKit (with user permission)
- iOS tap and UI tree via idb companion installation
- System CA installation for HTTPS decryption (Google APIs image)
- SOCKS5 MITM proxy for full TLS inspection
- Flutter widget inspector integration
- Automated test recording and playback

### Long-Term

- Multiple device simultaneous monitoring
- Cloud device integration (AWS Device Farm, Firebase Test Lab)
- Test framework integration (Appium, XCTest, Espresso)
- Custom automation scripting via wbctl
- Plugin system for extensibility

## What Makes QA Workbench Unique

**Comprehensive Integration:**
Unlike tools that focus on one aspect (network sniffing, UI inspection, or device control), QA Workbench combines all these capabilities in a single, unified interface.

**Zero External Swift Dependencies:**
By using only system frameworks and invoking external tools as child processes, QA Workbench maintains a small attack surface and reduces dependency management overhead.

**Multi-Source Network Monitoring:**
QA Workbench uniquely combines three network monitoring approaches:
- VM HTTP profile for Dart clients
- HTTP proxy for native clients
- Packet capture for all network activity
This provides complete visibility regardless of which HTTP client the app uses.

**Flutter-Native:**
Built with Flutter workflows in mind, including pseudo-terminal execution for proper debugPort publishing, automatic hot restart reconnection, and VM service integration.

**Vision Framework Integration:**
Leverages Apple's Vision framework for OCR and on-device translation, providing fast, accurate text recognition without cloud services.

**Privacy-First:**
All processing happens locally on your Mac. No cloud services, no telemetry, no data leaving your machine.

## Performance Characteristics

Based on Phase 0 spike measurements (see [SPIKES.md](docs/SPIKES.md)):

**Android Emulator (software renderer):**
- Frame rate: ~11 FPS at 540×1200 scaled resolution
- Frame latency: p50 46.8ms, p95 76.8ms
- Touch-to-pixel: ~115ms from sendTouch start
- UiAutomator dump: ~2.3 seconds per dump

**iOS Simulator:**
- Screenshot polling: ~1.8 FPS (547ms mean interval)
- No live video stream available without ScreenCaptureKit permission

**Vision OCR:**
- Warm recognition: ~337-521ms per frame
- Model load: ~3.7s on first call
- Supports 33 languages including Japanese

**Network Monitoring:**
- VM HTTP profile polling: ~500ms intervals
- Proxy event merge window: 250ms
- HAR export includes full request/response bodies

## License

This project is a QA Workbench implementation. See individual package licenses and [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md) for external dependency licenses.

## Contributing

Contributions are welcome. Please ensure:
- All tests pass: `scripts/test.sh`
- Code is formatted: `xcrun swift-format lint --recursive --strict`
- No new third-party Swift dependencies are added
- Changes are documented in relevant README files
