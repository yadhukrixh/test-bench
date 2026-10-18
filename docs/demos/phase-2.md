# Phase 2 demo

The window shows the live picture of a booted device. Android taps, Back, and Home go to the emulator. An APK can be chosen from disk or downloaded from an http or https address and installed on the running emulator. iOS is a slow series of screenshots, and taps stay unavailable. The inspector panes still say they are not in this version.

## What was run on 2026-10-14

`wbctl devices boot --id android:Pixel_8` booted headless and reported `emulator-5554`, gRPC 8554.

With `WB_GRPC_PORT=8554`, the mirror test asked `getScreenshot` for a 180×400 frame, opened `streamScreenshot`, and sent the `GoHome` key. The frame had a width, a height, and four bytes per pixel. The test passed in 0.136 seconds.

`adb -s emulator-5554 install -r -t` on `Spikes/spike_fixture/build/app/outputs/flutter-apk/app-debug.apk` printed `Success`.

`PackageFile.download` fetched that same APK from `http://127.0.0.1:8765/app-debug.apk` and the saved file started with the zip magic bytes.

`wbctl devices stop --id android:Pixel_8` left no `qemu-system` process.

## How to see it

```bash
scripts/bundle-app.sh
open "build/QA Workbench.app"
```

Choose `Pixel_8`, press Boot, and wait until the phone frame fills in. Click the picture to tap. Back and Home are under the picture. Install APK… picks a file. Download and install takes an `http` or `https` address, up to 200 MB, and installs it on that emulator.
