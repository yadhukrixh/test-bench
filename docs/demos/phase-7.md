# Phase 7 demo

Snapshots save a PNG of the current screen plus the UiAutomator XML dump. Capture uses a full-resolution Android frame when the mirror is up. Files land under `~/Library/Application Support/QA Workbench/snapshots`.

Device controls on Android: volume up/down (`AudioVolumeUp` / `AudioVolumeDown` through `sendKey`), rotate (`adb shell wm user-rotation lock`), and clipboard get/set (`ClipData.text` field 1 on the emulator gRPC).

The Network tab no longer intercepts TLS. Chrome and app backends keep working. HTTPS destinations still appear as CONNECT rows. Clients that ignore `http_proxy` (including Dart `HttpClient`) show up from on-device PCAPdroid capture as DNS and TLS SNI rows. Charles is not used: it needs a system CA this Play image cannot install, and mitmdump already covers the HTTP-proxy path.

## What was run on 2026-10-15

WBSnapshot wrote a 1×1 PNG and matching XML, then listed it. DeviceManager tests lock the next `wm user-rotation`. ClipData round-trips `hello`. Proxy addon tests include `ignore_connection` and CONNECT parse.

## How to see it

```bash
scripts/bundle-app.sh
open "build/QA Workbench.app"
```

Boot `Pixel_8` if it is not already up. Capture a snapshot from the left dock. Use Vol − / Vol +, Rotate, and Clipboard Get/Set under the phone frame. Open Chrome on the emulator and load a page; the Network tab should list CONNECT hosts without breaking the page.
