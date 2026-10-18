# QA Workbench status

## Current phase

Phase 7 is implemented. Snapshots save PNG plus UiAutomator XML. Android volume, rotate, and clipboard sit under the phone frame. Installed-build HTTP uses Attach plus mitmdump on the emulator `http_proxy` and PCAPdroid packet capture for DNS and TLS SNI. HTTPS is passed through so the guest keeps internet. The phone frame shows a live picture. The Android tree and Properties work. Flutter Run, Attach, hot reload, and hot restart sit on the Device tab. The Network tab lists VM HTTP profile requests, proxied HTTP, and packet-derived hosts. Text and Translate read the screen with Vision and on-device translation.

Native Swift was confirmed on 2026-10-14. See `docs/adr/0001-native-swift.md` and `docs/adr/0002-app-sandbox-off.md`.

## What was verified on 2026-10-15 (Phase 7)

Unit tests, warnings as errors, including WBSnapshot (PNG magic plus XML on disk). DeviceManager locks the next `wm user-rotation`. ClipData field 1 round-trips. ProxyFlow parses CONNECT and intercepts TLS. Default tests do not boot an emulator.

## Phase 7

- [x] PNG plus UiAutomator XML snapshots under Application Support
- [x] Capture from a full-resolution Android frame when the mirror is up
- [x] Clipboard get/set through `EmulatorController` `ClipData.text` field 1
- [x] Volume up/down through `sendKey` with W3C `AudioVolumeUp` / `AudioVolumeDown`
- [x] Rotate through `adb shell wm user-rotation lock`
- [x] TLS passthrough so emulator HTTPS pages and APIs keep working; CONNECT still listed
- [x] `docs/demos/phase-7.md`

## Phase 6

- [x] Node text and Vision OCR merged into a text layer
- [x] OCR on a full-resolution frame after the screen settles about 250 ms, only when Text or Translate is on
- [x] De-duplicate OCR against node text when IoU is at least 0.5 and the strings are similar
- [x] Selectable overlay, copy, and a Text tab list
- [x] Translator protocol with a SwiftUI `.translationTask` host in the App target
- [x] Language availability and an on-device badge; do not call the macOS 26-only `TranslationSession(installedSource:target:)` initializer
- [x] `docs/demos/phase-6.md`

## What was verified on 2026-10-15 (Phase 6)

Unit tests, warnings as errors, including WBVision (4): Vision box flip to device pixels, IoU de-dupe, node content-desc runs, translation cache. Default tests do not boot an emulator.

The empty Network tab for a release APK is expected when Dart ignores the system proxy and there is no VM service. Installed debug or profile APKs use Device tab → Attach. Native clients that honor `http_proxy` use mitmdump. For a debug run, the VM client waits for `getVM`, unwraps a `Success.json` extension result, subscribes to Isolate events before `streamListen`, and retries isolates until `ext.dart.io.getHttpProfile` is present.

## Phase 5

- [x] VM service JSON-RPC client on the `wsUri` from `app.debugPort`
- [x] `getVM` / `getIsolate`, probe `ext.dart.io.getHttpProfile` (not `isHttpProfilingAvailable`)
- [x] `httpEnableTimelineLogging` with `enabled=true`
- [x] Poll `getHttpProfile` with `updatedSince` about every 500 ms
- [x] Fetch bodies with `getHttpProfileRequest` when a request completes
- [x] Re-run `getVM` and re-enable logging after hot restart and Isolate events
- [x] Network tab: list, filters, search, headers, payload, response, copy cURL, HAR 1.2, pause, clear
- [x] Secrets masked in the UI and in HAR (`Authorization`, `Cookie`, `Set-Cookie`, common token fields)
- [x] Proxy engine: mitmdump on `127.0.0.1:18080`, guest `http_proxy` `10.0.2.2:18080`, merge with VM by method/URL/status within 250 ms
- [x] `flutter attach --machine` for installed debug or profile APKs
- [x] `docs/demos/phase-5.md`

## What was verified on 2026-10-15

Unit tests, warnings as errors: WBCore, WBProcess, WBDevices, WBMirror, WBInspect, WBFlutter (4), WBNetwork (4). `xcrun swift-format lint --recursive --strict` on Packages, Tools, and App reported nothing. Default tests do not boot an emulator or run `flutter run`.

A fake VM returned the recorded S4 `HttpProfile` for `GET https://example.com/`. The store wrote HAR 1.2 with `_source` `vm`. Response body bytes decoded to `<!doctype html>`. Proxy JSON lines parse to source `proxy` and merge with a VM row of the same method, URL, and start time. DeviceManager tests set and clear `http_proxy`. Homebrew cask `mitmproxy` 12.2.3 is installed; `mitmdump` is on `/opt/homebrew/bin`.

## Phase 4

- [x] `flutter run --machine` on a pseudo-terminal so `app.debugPort` is published
- [x] Parse machine events for `appId`, `wsUri`, `port`, and `baseUri`
- [x] `app.restart` with `appId`, `fullRestart`, `pause`, `debounce`
- [x] `app.stop` with `appId`, then SIGTERM / SIGKILL
- [x] Flutter pid record under Application Support so a leftover run is reaped
- [x] APK download uses `/usr/bin/curl`, then `adb install -r -t`, then `am start` from `aapt dump badging`
- [x] `docs/demos/phase-4.md`

## Phase 3

- [x] `Node` model from the UiAutomator attributes that actually appear in a dump
- [x] `adb exec-out uiautomator dump /dev/tty`, trailer stripped, one dump in flight
- [x] Hit testing in device pixels, smallest covering node
- [x] iOS tree reports that idb is missing
- [x] APKs already on the emulator can be listed and installed
- [x] `docs/demos/phase-3.md`

## Phase 2

- [x] In-process cleartext HTTP/2 client for `getScreenshot`, `streamScreenshot`, `sendTouch`, and `sendKey`
- [x] Scaled Android frames, taps, Back, and Home
- [x] iOS frames from `simctl` screenshots, without taps
- [x] Install an APK from a file, or download one from http or https and install it
- [x] `docs/demos/phase-2.md`

## Phase 1

- [x] Packages, `wbctl`, and the SwiftUI app
- [x] Supervisor restart and back-off unit tests
- [x] Doctor on a normal PATH and on a PATH that does not include the SDK tools
- [x] Boot and stop an AVD and a simulator
- [x] A leftover emulator is reaped on the next launch, and Stop shuts one down
- [x] `docs/demos/phase-1.md`

## Phase 0

Spikes are done. Evidence is in `docs/SPIKES.md`. S1, S3, and S4 passed. iOS live video, proxy CA install, and WebView inspection did not.

## Not done

Git has no `user.name` or `user.email`, so there is no commit and no phase tag. This project does not change git config.

iOS has screenshots and no tap path and no tree. Dart `HttpClient` still ignores the system proxy; packet capture lists DNS and TLS SNI for those sockets. This Play image cannot install a system CA, so HTTPS is passed through (no decrypted bodies). Translation languages may still need a download; S7 found `supported`, not `installed`.
