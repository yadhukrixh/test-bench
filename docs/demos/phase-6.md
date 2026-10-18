# Phase 6 demo

Text and Translate read the screen. Node strings (UiAutomator `text` and `content-desc`) merge with Vision OCR. An OCR line is dropped when its box overlaps a node with IoU at least 0.5 and the strings match. OCR runs on a full-resolution frame after the picture sits still about 250 ms, and only while Text or Translate is on.

Translation goes through SwiftUI `.translationTask` in the app. Screen text stays on this Mac. Languages may still need a download; S7 found Japanese↔English as `supported`, not `installed`.

## Network tab (Phase 5 follow-up)

Installed debug or profile APKs use Attach. Native HTTP uses the emulator proxy once Android is booted. Release Flutter has no VM service and Dart `HttpClient` ignores the system proxy, so those requests still do not appear.

A debug run that still showed nothing was a bug: the VM client now waits for `getVM`, retries isolates until `ext.dart.io.getHttpProfile` is registered, and unwraps `Success.json` extension payloads.

## What was run on 2026-10-15

WBVision unit tests converted a Vision box (origin at the bottom) to device pixels, dropped overlapping OCR against node text, read `content-desc` from a node tree, and stored a translation cache entry.

## How to see it

```bash
scripts/bundle-app.sh
open "build/QA Workbench.app"
```

Boot `Pixel_8`. Turn on Text. Boxes appear after the screen settles. Click one and Copy. Turn on Translate for an overlay; macOS may ask to download languages.

For Network: Choose a Flutter project, Run, open the fixture Network lab, fire a request, then open the Network tab.
