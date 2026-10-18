# Phase 5 demo

The Network tab lists HTTP requests from a debug Flutter run. They come from the Dart VM HTTP profile: `ext.dart.io.httpEnableTimelineLogging`, `getHttpProfile` with `updatedSince`, and `getHttpProfileRequest` for bodies. Hot restart calls `getVM` again and re-enables logging on the new isolate.

Installed debug or profile APKs use Device tab → Attach (`flutter attach --machine`). Native HTTP uses mitmdump on `127.0.0.1:18080` and `adb shell settings put global http_proxy 10.0.2.2:18080`. VM and proxy rows merge when method, URL, optional status, and start time (250 ms) match. Release Flutter has no VM service. Dart `HttpClient` ignores the system proxy. This Play image cannot install a system CA, so HTTPS MITM often fails until the mitmproxy CA is a user-trusted cert.

Snapshots and Text still say they are not in this version. iOS still has no tree and no taps.

## What was run on 2026-10-15

WBFlutter unit tests parsed a VM `getVM` result, `extensionRPCs` that include `ext.dart.io.getHttpProfile`, an Isolate `streamNotify`, and `httpEnableTimelineLogging` with `enabled` as the string `true`.

WBNetwork unit tests parsed a recorded `HttpProfile` for `GET https://example.com/` status 200, decoded `responseBody` bytes that begin with `<!doctype html>`, wrote HAR 1.2 with `_source` `vm` and masked `Authorization`, and drove a fake VM through `streamListen`, `getVM`, `getIsolate`, `httpEnableTimelineLogging`, and `getHttpProfile`. Default tests do not boot an emulator or run `flutter run`.

## How to see it

```bash
scripts/bundle-app.sh
open "build/QA Workbench.app"
```

Boot `Pixel_8` if it is not already up. On the Device tab, Choose project… then Run a debug Flutter app, or install a debug/profile APK and press Attach. Open the Network tab. Fire requests from the app (the spike fixture Network lab is one source). Pause, Clear, search, and HAR… are on that tab. Click a row for headers, payload, and response. Copy cURL uses the real headers. HAR masks secrets. Native clients that honor the emulator proxy appear with source `proxy`.
