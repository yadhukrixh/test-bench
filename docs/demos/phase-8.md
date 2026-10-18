# Phase 8 demo

The Web tab lists inspectable Chrome and WebView pages on a booted Android emulator. It uses the abstract sockets S8 recorded (`chrome_devtools_remote`, `webview_devtools_remote_<pid>`), `adb forward` to a local port, `GET /json/list`, and Chrome DevTools `Runtime.evaluate` for the document title, location, and HTML.

A tester release APK without WebView debugging does not appear. Open Chrome on the emulator after the first-run screens, or use an app that calls `WebView.setWebContentsDebuggingEnabled(true)`. iOS stays unavailable: `simctl` has no inspect verb.

## What was run on 2026-10-16

S8 opened Chrome on Pixel_8, dismissed first-run, and listed `chrome_devtools_remote`. `/json/version` reported Chrome/154 and `/json/list` returned `Example Domain` at `https://example.com/`. Unit tests parse that listing and the JSON. DeviceManager tests include `adb forward tcp:19222 localabstract:chrome_devtools_remote`.

## How to see it

```bash
scripts/bundle-app.sh
open "build/QA Workbench.app"
```

Boot `Pixel_8` if it is not already up. Open Chrome on the emulator, skip sign-in, and load a page. Open the Web tab and press Refresh. The page title, URL, socket name, and HTML should appear.
