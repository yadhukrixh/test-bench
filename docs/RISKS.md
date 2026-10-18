# Risk register

The brief's original table was not included in the working copy of the specification. This register is the Phase 0 update: what this machine actually showed. Likelihood and impact use the brief's scale (H/M/L) and are estimates from those runs.

| Id | Risk | L | I | Evidence | Fallback |
| --- | --- | --- | --- | --- | --- |
| R1 | Software GPU makes the Android mirror about 11 fps, and `-gpu host` invalidates the saved snapshot | H | H | S1. Snapshot load failed with "different renderer". Scaled and full streams were both ~11 fps | Pin one GPU mode, save a new snapshot, remeasure on `-gpu host` before accepting a frame-rate budget |
| R2 | Full RGBA frames exceed gRPC's 4 MB default and trip `recvmsg` "Message too long" | H | M | S1. 10,368,035 bytes rejected until the limit was raised | Cap the live stream. Fetch full resolution only for OCR and snapshots |
| R3 | The screenshot stream does not tick while the screen is still | H | L | S1. One frame in 3 s on the home screen, 70 frames in 6 s while swiping | Drive the canvas from the last frame. Do not treat a quiet stream as a failure |
| R4 | Unicode does not travel through `sendKey` | H | M | S1. Japanese `sendKey` text and `key=Paste` did nothing. Ctrl+V after `setClipboard` worked | Clipboard plus adb Ctrl+V for non-ASCII |
| R5 | `flutter run --machine` hides `app.debugPort` when stdout is not a pty | H | H | S3. The event was missing on a pipe and present on a pty | Spawn Flutter on a pseudo-terminal |
| R6 | Hot restart keeps `wsUri` and replaces the isolate | H | H | S3. Isolate id changed, no second `app.debugPort` | Always re-run `getVM` and re-enable extensions after restart |
| R7 | iOS has no proven live frame source or touch path | H | H | S2. No idb. ScreenCaptureKit TCC `-3801`. `simctl` screenshot ~1.8 fps and no tap API | Degrade iOS to polling, or hold iOS mirror until the signed app gets Screen Recording |
| R8 | Play images cannot take a system CA | H | H | S5. `adb root` → "adbd cannot run as root in production builds" | VM HTTP profile for debug apps. Proxy only after a Google APIs image is installed |
| R9 | Removing an iOS simulator CA clears the whole keychain | M | H | S5. `add-root-cert` works. The only removal command is `keychain reset` | Warn before reset. Do not reset a simulator the user did not just create |
| R10 | Translation models are not installed, and the UI-less session initializer needs macOS 26 | H | M | S7. Status `supported`. `installedSource` is `@available(macOS 26)` and threw `notInstalled` | SwiftUI `.translationTask` on a macOS 15 target. Prompt for the download |
| R11 | UiAutomator dumps are slow and append a trailer | H | M | S6. About 2.3 s. Trailer `UI hierchary dumped to: /dev/tty` | One dump in flight. Strip the trailer. Do not poll while the screen is still |
| R12 | WebView inspection is unproven | M | M | S8 was not run | Keep the feature off |
| R13 | Select Widget Mode's on-device controls steal taps | M | M | S3. The dump gained "Exit Select Widget mode" over the bottom of the screen | Turn `show` off before sending a navigation tap |
| R14 | Discovery pid files survive the emulator | M | M | S1. `pid_19682.ini` was still in the cache after `adb emu kill` | Ignore a pid file whose process is dead, and delete ones this app wrote |

Reviewed at the end of Phase 0. Review again at the end of each later phase.
