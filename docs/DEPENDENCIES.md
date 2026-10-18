# Dependencies

Phase 0 throwaway tools only. Nothing here is linked into an app yet. Versions are the ones installed for the spikes.

| Dependency | Version | Where | License |
| --- | --- | --- | --- |
| grpcio | 1.76.0 | `Spikes/.venv` | Apache-2.0 |
| grpcio-tools | 1.76.0 | `Spikes/.venv` | Apache-2.0 |
| protobuf | 6.32.1 | `Spikes/.venv` | BSD-3-Clause |
| websockets | 15.0.1 | `Spikes/.venv` | BSD-3-Clause |
| http (Dart) | 1.6.0 | `Spikes/spike_fixture` | BSD-3-Clause |
| dio | 5.11.1 | `Spikes/spike_fixture` | MIT |
| Android emulator | 36.5.11.0 build 15261927 | system SDK, not vendored | Apache-2.0 (emulator); proto copied from `emulator/lib/emulator_controller.proto`, sha256 `e872af01d8ff0a46d2d19c644709e4d524be609e9cff69f75b06ab0bb67653dd`. The SDK does not ship a git commit. The proto header is Apache-2.0 |
| Flutter | 3.41.8 stable | `~/develop/flutter`, not vendored | BSD-3-Clause |
| Xcode / Simulator / Vision / Translation | 26.3 | system | Apple SDK license |

The Python virtualenv and generated stubs are gitignored. Reinstall from `Spikes/requirements.txt`.

## Phase 1

The app and `wbctl` link no third-party Swift packages. Device readiness calls `EmulatorController.getStatus` through `/usr/bin/curl`, which ships with macOS. The emulator proto is not compiled into the app. Field numbers used for `booted` are the ones in `Spikes/protos/emulator_controller.proto` (`EmulatorStatus.booted = 3`).

## Phase 2

Still no third-party Swift packages. The live picture uses Network.framework, which ships with macOS, to speak cleartext HTTP/2 to `EmulatorController`. Screenshot and touch field numbers are the ones in `Spikes/protos/emulator_controller.proto`: `ImageFormat.format = 1`, `width = 3`, `height = 4`, `Image.image = 4`, `Touch.x = 1`, `y = 2`, `identifier = 3`, `pressure = 4`, `KeyboardEvent.eventType = 2`, `key = 4`. APK install is `adb install -r -t`. Downloads originally used `URLSession`.

## Phase 3

Still no third-party Swift packages. The tree is `adb exec-out uiautomator dump /dev/tty`. The parser strips the trailer `UI hierchary dumped to: /dev/tty` and reads the XML attributes Android actually emits: `class`, `package`, `resource-id`, `text`, `content-desc`, `bounds`, and the boolean flags. Node bounds stay `[l,t][r,b]` in device pixels. An APK already on the emulator is copied with `adb pull` and installed with the same `adb install -r -t`. idb is still missing, so there is no iOS tree.

## Phase 4

Still no third-party Swift packages. Flutter is driven with `flutter run --machine` on a POSIX pseudo-terminal (`posix_openpt`). Machine events are JSON arrays. `app.debugPort` supplies `port`, `wsUri`, and `baseUri`. Reload is `app.restart` with `appId`, `fullRestart`, `pause`, and `debounce`. Stop is `app.stop` with `appId`. APK downloads use `/usr/bin/curl -L --fail --max-filesize`. After `adb install -r -t`, launch is `aapt dump badging` then `adb shell am start -n package/activity`, with `monkey` as a fallback. The bundled app Info.plist sets `NSAllowsArbitraryLoads` so an http APK address is not blocked.

## Phase 5

Still no third-party Swift packages. The VM client uses `URLSessionWebSocketTask` on `wsUri`. Calls are JSON-RPC 2.0: `getVM`, `getIsolate`, `streamListen` with `streamId=Isolate`, `ext.dart.io.httpEnableTimelineLogging` (`enabled` string `true`), `ext.dart.io.getHttpProfile` (`updatedSince` microseconds), `ext.dart.io.getHttpProfileRequest` (`id`), and `ext.dart.io.clearHttpProfile`. Profile request fields used: `id`, `isolateId`, `method`, `uri`, `startTime`, `endTime`, `events`, `request`, `response`, `requestBody`, `responseBody`. HAR is version 1.2 with `_source`. A `Success.json` wrapper around an extension result is unwrapped before `requests` is read. Installed-app capture uses `flutter attach --machine` plus mitmdump (`--listen-host 127.0.0.1 --listen-port 18080`) and `adb shell settings put global http_proxy 10.0.2.2:18080`. The mitmproxy addon is embedded in WBNetwork and writes JSON lines under Application Support. VM and proxy events merge when method, URL, optional status, and start time (250 ms) match. Clear the guest proxy with `settings put global http_proxy :0`.

## Phase 6

Still no third-party Swift packages. OCR is Vision (`VNRecognizeTextRequest`, languages `ja-JP` and `en-US` when supported, language correction on). Translation uses SwiftUI `.translationTask` in the App target. The macOS 26-only `TranslationSession(installedSource:target:)` initializer is not called. Language detection uses `NLLanguageRecognizer`.

## Phase 7

Still no third-party Swift packages. Snapshots are PNG via ImageIO plus the UiAutomator XML. Clipboard uses `ClipData.text` field 1 on `setClipboard` / `getClipboard`. Volume uses `KeyboardEvent.eventType = 2` and `key = 4` with W3C `AudioVolumeUp` / `AudioVolumeDown`. Rotate is `adb shell wm user-rotation lock`. The mitmproxy addon sets `tls_clienthello` `ignore_connection` so HTTPS is not MITM'd; `http_connect` still emits CONNECT rows.

On-device capture uses the PCAPdroid APK (`com.emanuelef.remote_capture`, GitHub release v2.0.2, GPLv3) installed with `adb install -r -t` when missing. Capture is `CaptureCtrl` `tcp_exporter` to `127.0.0.1:18081` after `adb reverse`. SOCKS5 and TLS decryption stay off so Flutter keeps internet. The workbench parses PCAP for DNS QNAME, TLS ClientHello SNI, and cleartext HTTP. The emulator console `network capture start` was tried on this Pixel_8 qemu and wrote only a 24-byte PCAP header, so it is not used.
