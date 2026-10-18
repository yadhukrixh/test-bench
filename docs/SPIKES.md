# Phase 0 spikes

Recorded 2026-10-14 on this machine. Every result below was observed here. Commands and field names that the brief marked "verify" are answered from those runs, or called out where the tool was not available.

## Environment

| Item | Observed |
| --- | --- |
| Host | Apple M4, 16 GB, macOS 26.2 (25C56), arm64 |
| Xcode | 26.3 (17C529), Swift 6.2.4 |
| Flutter | 3.41.8 stable, Dart 3.11.5, DevTools 2.54.2, framework revision 02085feb3f |
| Android SDK | 36.1.0 at `~/Library/Android/sdk`. Emulator 36.5.11.0, build 15261927 |
| AVD | `Pixel_8` only. API 37, `google_apis_playstore_ps16k` arm64, 1080×2400, 420 dpi, `hw.keyboard=yes` |
| iOS | iOS 26.3 runtime only. Used iPhone 17 `15AB8309-1B82-4862-BAE8-AEA1F118A0AB` |
| idb | Not installed. `brew search idb` and `brew info idb-companion` found no formula |
| mitmdump | Not installed. Homebrew cask `mitmproxy` 12.2.3 exists |

This is not the brief's API 30–35 Google APIs matrix, and not iOS 17. The Play image is not rootable. That constraint is measured in S5, not assumed away.

Section 12's numeric performance table was not in the brief. The numbers below are the baseline. No budget was adjusted.

## S1 — Android frames and touch: pass

Launch that produced the numbers:

```text
emulator -avd Pixel_8 -port 5554 -grpc 8554 -no-window -no-audio -no-boot-anim
```

GPU landed on lavapipe / swangle (software). Forcing `-gpu host` refused the existing `default_boot` snapshot: "Change of GLES renderer detected" and "Failed to load snapshot 'default_boot'". The software-renderer launch loaded that snapshot in 1364 ms. Frame rate and latency below are the software renderer, not a Metal host GPU.

### gRPC access

- Log line: `Started GRPC server at [::]:8554, security: Insecure, auth: none`.
- The same log says to consider `-grpc-use-jwt`. Without that flag, no token is required. `emulator -help-grpc` matches this. The summary help line that calls JWT the default does not match the run.
- Discovery file, written by the emulator: `~/Library/Caches/TemporaryItems/avd/running/pid_<pid>.ini`. Fields observed: `emulator.build`, `emulator.version`, `avd.id`, `avd.name`, `avd.dir`, `port.serial` (5554), `port.adb` (5555), `grpc.port` (8554), `grpc.allowlist`, `cmdline`, `launcher.dir`. No token field.
- The file can outlive the process. A dead pid must be treated as stale.
- `getStatus` reported `booted: true` and version `36.5.11.0 (36.5.11-15261927)`. `guestConfig` was empty on this image.
- A full RGBA frame is 1080×2400×4 = 10,368,000 bytes. The default gRPC limit rejected it: `Received message larger than max (10368035 vs. 4194304)`. The client used a 32 MB receive limit.
- Pixel order in `Image.image` is left to right, bottom up, as the proto says. Sampling with that flip returned pure white `(255,255,255,255)` and, after a tap, pure red `(255,0,0,255)`.
- Full-size frames also logged `recvmsg encountered uncommon error: Message too long`. The 540×1200 stream did not. Live view should stay scaled.

### Frame rate

`streamScreenshot` sends a frame when the display updates. A static home screen produced 1 frame in 3 seconds. While `adb shell input swipe` was moving the launcher:

| Stream | Frames / window | FPS | Host interval p50 | p95 | Bytes |
| --- | --- | --- | --- | --- | --- |
| RGBA 1080×2400 | 70 / 6.009 s | 11.65 | 46.8 ms | 160.4 ms | 692 MB |
| RGBA 540×1200 | 66 / 6.003 s | 10.99 | 48.5 ms | 76.8 ms | 163 MB |

Sequence gaps were 0. Scaling did not raise FPS, so the software renderer is the limit, not the 10 MB messages. Empty frames: 0.

### Touch, keys, text

- UiAutomator bounds for the Settings icon were `[836,1905][1009,2100]`. A gRPC tap at the center `(922, 2002)` opened Settings. `GoBack` returned to the launcher. `GoHome` returned to the launcher from Settings.
- The fixture reported the center tap as `px 540.0,1199.9` at `dpr 2.625`. The requested point was `(540, 1200)`. Error is under 1 device pixel.
- Touch-to-pixel: the center pixel went from white to red on the first frame after the tap pair, 115.5 ms from the start of `sendTouch` and 114 ms after both RPCs returned.
- `sendKey` `key=GoBack` and `key=GoHome` with `eventType=keypress` both returned OK and changed the focused activity.
- `sendKey` `text=hello` appeared in the fixture `EditText`. `sendKey` `text=ログイン` returned OK and did not appear.
- `setClipboard` / `getClipboard` round-tripped `ログイン` and `hello-qa`.
- `sendKey` `key=Paste` returned OK and did not insert. `adb shell input keyevent KEYCODE_PASTE` did not insert.
- `adb shell input keycombination KEYCODE_CTRL_LEFT KEYCODE_V` after `setClipboard` inserted `貼付`.

Chosen Android input path: gRPC touch and `sendKey` for hardware keys and ASCII. Unicode goes through gRPC `setClipboard` plus an adb Ctrl+V chord. The gRPC keyboard message has no modifier chord.

## S2 — iOS frames and input: partial

Tested in the required order.

1. **idb video stream: fail / blocked.** `idb` is not on `PATH` and Homebrew has no `idb-companion` formula. No stream was measured. idb `ui tap` and `ui swipe` were not run.
2. **ScreenCaptureKit: blocked on permission.** Simulator.app was open. `SCShareableContent` from an ad-hoc binary and from an app bundle with `NSScreenCaptureUsageDescription` both failed immediately: `SCStreamErrorDomain` code `-3801`, "The user declined TCCs for application, window, display capture". No frames. A signed app that the user approves in System Settings is still a candidate; this spike did not get that grant, and the grant needs a restart.
3. **`simctl io screenshot` polling: works, too slow for a live mirror.** The Simulator.app did not need to be running. First capture 2030 ms, then 1005, 451, 282, 439, 559 ms. Mean 547 ms, about 1.8 fps. Image 1206×2622 PNG.

`simctl io` operations are `enumerate`, `poll`, `recordVideo`, and `screenshot`. There is no live frame stream. `recordVideo` writes a movie file. `simctl ui` sets appearance, contrast, and content size. It does not tap or swipe.

Chosen iOS frame path for now: do not promise a live mirror. `simctl` polling is the degraded fallback. Revisit ScreenCaptureKit once the real app can request Screen Recording. Revisit idb only if the companion can be installed.

## S3 — Flutter debug: pass

`flutter run --machine -d emulator-5554` on `Spikes/spike_fixture`.

A pipe that is not a pseudo-terminal delivered `daemon.connected` (protocol 0.6.1), `app.start`, and `app.progress`, and did not deliver `app.debugPort` in the captured stdout even after the app was on screen. The service was still up: an HTTP GET of the forwarded port returned a 302 to the DevTools URI. On a pty, `app.debugPort`, `app.devTools`, and `app.started` arrived together, 10.5 s after start on a warm install.

Observed `app.debugPort` fields: `port`, `wsUri`, `baseUri`. Use `wsUri`. `app.devTools.uri` was present.

VM: Dart 3.11.5, one `main` isolate, 73 extension RPCs. Inspector RPCs listed in the brief are present, including `getRootWidgetSummaryTree`, `getSelectedSummaryWidget`, `show`, `isWidgetTreeReady`, `addPubRootDirectories`. `isWidgetTreeReady` was true. `isWidgetCreationTracked` was true.

`addPubRootDirectories` with `arg0` set to `file:///Users/yadhu/Documents/qa-bench/Spikes/spike_fixture` produced a summary tree whose user widgets are marked `createdByLocalProject`. The tree included `SpikeApp`, `MaterialApp`, and `TouchLab` with `creationLocation` pointing at `lib/main.dart`. It was not empty (about 7.6 KB for the summary).

Argument names read from Flutter 3.41.8 `widget_inspector.dart`, not guessed:

| RPC | Parameters |
| --- | --- |
| `getRootWidgetSummaryTree` | `objectGroup` |
| `getRootWidgetSummaryTreeWithPreviews` | `groupName` (different name) |
| `getSelectedSummaryWidget` | `arg`, `objectGroup` |
| `show` | `enabled` = `true` or `false` |
| `addPubRootDirectories` | `arg0`, `arg1`, ... |
| `isWidgetTreeReady`, `isWidgetCreationTracked` | none |

`show` enabled, then a tap, then `getSelectedSummaryWidget` returned `MaterialApp` created at `main.dart` line 17. Select mode also injected its own accessibility controls into the dump ("Exit Select Widget mode", "Move to the right"). Those controls sit on top of bottom buttons, so navigation taps must turn `show` off first.

`app.restart` parameters read from `daemon.dart`: required `appId`; `fullRestart` defaults false; `pause`, `reason`, and `debounce` optional.

| Step | Result |
| --- | --- |
| Hot reload (`fullRestart: false`) after a one-line edit | `code: 0`, "Reloaded 1 of 905 libraries". Isolate id unchanged |
| Hot restart (`fullRestart: true`) | `code: 0`. No new `app.debugPort`. Same `wsUri` still answered `getVM`. Isolate id changed (`…732191154330119` to `…106237071339959`) |

After a hot restart the client must call `getVM` again and re-enable extensions on the new isolate even when `wsUri` did not change.

## S4 — HTTP profile: pass

`isHttpProfilingAvailable` is not registered on Dart 3.11.5. The probe is the presence of `ext.dart.io.getHttpProfile`. Registered RPCs: `httpEnableTimelineLogging`, `getHttpProfile`, `getHttpProfileRequest`, `clearHttpProfile`, plus the socket RPCs and `getVersion`.

`httpEnableTimelineLogging` with `enabled=true` returned `HttpTimelineLoggingState`. `getHttpProfile` omitted bodies. `getHttpProfileRequest` with `id` returned `requestBody` and `responseBody` as arrays of byte values. A `dart:io` GET of `https://example.com/` was status 200, `compressionState` `decompressed`, and the body began with `<!doctype html>` (577 bytes).

One button then fired three clients. Each appeared once:

| Client | Request | Status | Body |
| --- | --- | --- | --- |
| `dart:io` | POST `https://example.com/dart-io` | 405 | request body `{"source":"dart:io"}` |
| `package:http` 1.6.0 | GET `https://example.com/http-pkg` | 404 | profiled |
| `dio` 5.11.1 | GET `https://example.com/dio-pkg` | 404 | profiled |

On this Android debug build, `package:http` and `dio` use `dart:io`, so they are in the VM profile. The brief's gap (native SDKs and WebViews) was not given a counterexample in this spike: the fixture has no OkHttp client and no WebView. Treat that gap as still expected, and unmeasured.

## S5 — CA trust: partial

`adb root` on `Pixel_8`: `adbd cannot run as root in production builds`. `adb remount` is not a shell command here. `id` is `uid=2000(shell)`. `/system/etc/security/cacerts` exists and contains 145 files, and it is not writable from this session. No CA was installed. No Flutter trust test was run. API level is 37 (release 17), not 34, and the image is Play Store, not Google APIs.

iOS command, from `xcrun simctl help keychain` on Xcode 26.3:

```text
xcrun simctl keychain <udid> add-root-cert <path>
xcrun simctl keychain <udid> add-cert <path>
xcrun simctl keychain <udid> reset
```

`add-root-cert` of a one-day self-signed PEM succeeded on the booted iPhone 17. There is no remove-one-cert command. `keychain reset` succeeded and clears the whole simulator keychain; this spike ran it immediately so the test CA would not stay behind. Routing an app through a proxy and `SIMCTL_CHILD_` were not tested. mitmdump is not installed. The Mac trust store was not modified.

## S6 — node sources: partial

`adb exec-out uiautomator dump /dev/tty` works. Two runs took 2.25 s and 2.34 s. Stdout is the XML plus a trailer, including the product's own typo: `UI hierchary dumped to: /dev/tty`. Parsers must cut that trailer off. Bounds are `[l,t][r,b]` in device pixels. The launcher dump's first labelled widget started at y=161, so the status bar is outside that widget. The hierarchy root covers the full screen.

Flutter 3.41.8 debug, no companion semantics toggle: the dump was not a bare shell. 11 nodes. Labels arrived as `content-desc`, with `text=""`. The touch report, "ログインして続行", and the buttons were all content descriptions. `EditText` carried its value in `text`. The on-device inspector, while `show` was on, added its own buttons to the same dump.

This does not contradict "semantics are collected while an accessibility client is connected": `uiautomator dump` is that client. A dump with no accessibility client was not separately possible. The community report of a bare shell was not reproduced for this Flutter version.

idb `describe-all` was not run. No native Android or iOS fixture was built. Coordinate ground truth for Flutter is the fixture's own report (S1), which matched the gRPC tap within 0.1 px. Flutter's log gave insets `statusBars:[0,132,0,0]` and `navigationBars:[0,0,0,63]` on the 1080×2400 display.

## S7 — Vision and Translation: partial

Vision `supportedRecognitionLanguages()` on this OS includes `ja-JP` and `en-US` (33 languages total; list is in the spike output).

A rendered card with the English sentence and `ログインして続行してください。これは品質確認のための文章です。` was recognized at confidence 1. English matched exactly. Japanese was split after `品質確` / `認のための` and matched exactly when the two lines were joined. The bitmap came out 2160×4800 because `NSImage` on this display is 2x, not the requested 1080×2400. Warm recognition was 521 ms, then 337 ms. An earlier call before the text was actually drawn took 3702 ms and returned no lines; treat that as model load, not a blank-image rate.

`LanguageAvailability.status` for Japanese→English and English→Japanese is `supported`, which is not `installed`.

`TranslationSession(installedSource:target:)` exists and is marked `@available(iOS 26.0, macOS 26.0, *)` in the Xcode 26.3 SDK. It is not available on the brief's macOS 15 deployment target. Calling it here threw `TranslationError.Cause.notInstalled`. SwiftUI `translationTask` is in `_Translation_SwiftUI` and is available from macOS 15.0. No language download was completed, so throughput of a translation was not measured. The download still needs a SwiftUI host and the user's consent.

## S8 — WebView debugging: not run

The fixture has no WebView. No `webview_devtools_remote` socket was inspected, and the Simulator Safari bridge was not tested. WebView inspection stays off until this spike is run.

## Gate

S1, S3, and S4 pass. Phase 1 may start after the stack is confirmed.

## Chosen approach

| Capability | Decision |
| --- | --- |
| Android frames | gRPC `streamScreenshot`, RGBA, scaled for the live view, full resolution on demand. Raise the gRPC receive limit. Hide the emulator behind `FrameSource`. |
| Android input | gRPC touch and keys. Unicode via `setClipboard` plus adb Ctrl+V. |
| Android nodes | `uiautomator dump /dev/tty`, content-desc for Flutter labels. |
| Flutter source mode | `flutter run --machine` on a pty. Drive `wsUri`. Re-read isolates after hot restart. |
| Network, debug builds | VM HTTP profile. It already sees `dart:io`, `package:http`, and `dio`. |
| Proxy CA | Not available on the Play image. Do not promise it until a Google APIs image is installed. iOS uses `simctl keychain add-root-cert`, and removal is a full keychain reset. |
| iOS frames | Degraded `simctl` polling only, until Screen Recording works in the real app or idb is installed. |
| iOS input | Unproven. No idb, and `simctl` has no tap. |
| OCR | Vision, Japanese included. Run on a full-resolution frame. |
| Translation | SwiftUI `.translationTask` host in the app. Do not call the macOS 26-only initializer from a macOS 15 target. Languages are not installed yet. |
| WebView | Off. |

## Stack recommendation

Native Swift, as section 4 describes: one macOS process, source protocols, helpers for `adb`, `emulator`, `simctl`, and `flutter`. Tauri would still need the same Swift and gRPC and VM-service work for frames, OCR, and translation, and ScreenCaptureKit plus Translation want an AppKit/SwiftUI host. The owner confirms this at the end of Phase 0.
