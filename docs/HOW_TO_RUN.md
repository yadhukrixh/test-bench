# How to run this

Phase 7 is the QA Workbench app. It shows the live picture of a booted device, the Android hierarchy, snapshots, Android volume/rotate/clipboard, a Flutter run or attach on a pseudo-terminal, the VM HTTP profile and emulator HTTP proxy, and on-screen text. Phase 0 probes are still in `Spikes/` and are described further down.

## Open the app

From the repository root:

```bash
cd /Users/yadhu/Documents/qa-bench
scripts/bundle-app.sh
open "build/QA Workbench.app"
```

The first launch asks you to confirm that you will only test apps and devices you are allowed to test. After that, the window has a device menu, Boot, Stop, and Doctor.

Choose `Pixel_8` and press Boot. The emulator starts without its own window. When it finishes booting, the phone frame shows the screen and the left dock fills with the UiAutomator tree. Click a row to select it. Turn on Inspect and click the picture to select the smallest node under that point. Properties lists the dump attributes. Refresh asks for another dump. A tap, Back, or Home also dumps again.

Install APK… picks a file on this Mac. Download, install, and run takes an `http` or `https` address, refuses anything over 200 MB, downloads it with curl, installs it, and opens it. On the emulator lists APKs already on the device under `/sdcard`, `/sdcard/Download`, `/sdcard/Downloads`, `/data/local/tmp`, and the matching `/storage/emulated/0` folders. Install and run copies the chosen file off the device, installs it, and opens it.

On the Device tab, Choose project… then Run starts `flutter run --machine` for the booted device. Attach starts `flutter attach --machine` against an installed debug or profile APK (a project folder is optional). Console shows the machine events. Hot reload and Hot restart send `app.restart`. Stop Flutter sends `app.stop`. After a hot restart the workbench calls `getVM` again so the HTTP profile stays attached.

The Network tab lists `dart:io` / `package:http` / `dio` from a debug or profile VM, native HTTP that honors the emulator proxy (`10.0.2.2:18080`), and hosts from on-device packet capture (DNS and TLS SNI). HTTPS is passed through so the app keeps internet. Do not open `http://127.0.0.1:18080` in a Mac browser. The first Android boot may download PCAPdroid and show a VPN permission dialog; the workbench taps OK when it can. Pause, Clear, search, and HAR export are on that tab.

Turn on Text or Translate in the toolbar. After the screen sits still, OCR and node strings fill the Text tab and boxes on the picture. Click a box to select it. Copy or Command-C copies. Translate uses on-device `.translationTask` and may ask to download languages.

Capture in the left dock saves a PNG plus the Android XML dump. Under the phone frame: Back, Home, volume, Rotate, and clipboard Get/Set.

An iOS simulator shows screenshots about twice a second. Taps, volume, rotate, clipboard, and the tree are not available there.

Doctor lists what is installed. A warning for `idb` is expected on this Mac. Network capture uses `mitmdump` from `~/Library/Application Support/QA Workbench/mitmvenv`, not the Homebrew cask. If macOS shows “Apple could not verify mitmproxy”, dismiss it with Done; that dialog is Gatekeeper on the cask, and the workbench does not need that copy. Copy fixes does not edit your shell profile. `wbctl doctor --fix` writes `~/Library/Application Support/QA Workbench/env.sh`, which does nothing until you `source` it.

## Command line

`scripts/doctor` builds `wbctl` if needed and runs the doctor.

```bash
scripts/doctor
Tools/wbctl/.build/debug/wbctl devices list
Tools/wbctl/.build/debug/wbctl devices boot --id android:Pixel_8
Tools/wbctl/.build/debug/wbctl devices stop --id android:Pixel_8
Tools/wbctl/.build/debug/wbctl devices boot --id ios:15AB8309-1B82-4862-BAE8-AEA1F118A0AB
Tools/wbctl/.build/debug/wbctl devices stop --id ios:15AB8309-1B82-4862-BAE8-AEA1F118A0AB
```

The iOS id is the iPhone 17 simulator on this Mac. `devices list` prints the ids.

Put the SDK and Flutter on `PATH` if the doctor warns that they were found but are not on `PATH`:

```bash
export ANDROID_SDK_ROOT="$HOME/Library/Android/sdk"
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export PATH="$ANDROID_SDK_ROOT/emulator:$ANDROID_SDK_ROOT/platform-tools:$HOME/develop/flutter/bin:$PATH"
```

## Tests

```bash
scripts/test.sh
```

That runs the unit tests and builds `wbctl` and the app with warnings treated as errors.

## One-time probe setup

The virtualenv and the generated gRPC stubs are gitignored. Recreate them if `Spikes/.venv` is missing:

```bash
python3 -m venv Spikes/.venv
Spikes/.venv/bin/pip install -r Spikes/requirements.txt
PROTO_INC=$(Spikes/.venv/bin/python -c "import grpc_tools, pathlib; print(pathlib.Path(grpc_tools.__file__).parent / '_proto')")
mkdir -p Spikes/gen
Spikes/.venv/bin/python -m grpc_tools.protoc \
  -I Spikes/protos -I "$PROTO_INC" \
  --python_out=Spikes/gen --grpc_python_out=Spikes/gen \
  Spikes/protos/emulator_controller.proto
```

## Phase 0 probes

These are not the app. They are the measurements recorded in [SPIKES.md](SPIKES.md).

### Android

Start the emulator, then run a probe from another terminal:

```bash
emulator -avd Pixel_8 -port 5554 -grpc 8554 -no-window -no-audio -no-boot-anim -crash-report-mode disabled
Spikes/.venv/bin/python Spikes/s1_android.py --mode status
Spikes/.venv/bin/python Spikes/s1_android.py --mode sample-pixel
Spikes/.venv/bin/python Spikes/s1_android.py --mode frames --seconds 6 --width 540 --height 1200
Spikes/.venv/bin/python Spikes/s1_android.py --mode clipboard
Spikes/.venv/bin/python Spikes/s1_android.py --mode input
adb -s emulator-5554 emu kill
```

### Flutter

`flutter run --machine` has to run in a real terminal, not a pipe, or the debug port is missing. From `Spikes/spike_fixture`:

```bash
flutter run -d emulator-5554 --machine
```

When `app.debugPort` appears, in another terminal:

```bash
Spikes/.venv/bin/python Spikes/s3_vm.py --ws 'ws://127.0.0.1:PORT/TOKEN/ws' --pub-root "$PWD"
```

Use the `wsUri` from that session. The token changes every run.

### Vision

```bash
xcrun swiftc -parse-as-library -O -o Spikes/s7_vision Spikes/s7_vision.swift
Spikes/s7_vision
```

### Simulator screenshots

```bash
xcrun simctl boot 15AB8309-1B82-4862-BAE8-AEA1F118A0AB
Spikes/s2_simctl.sh 15AB8309-1B82-4862-BAE8-AEA1F118A0AB
xcrun simctl shutdown 15AB8309-1B82-4862-BAE8-AEA1F118A0AB
```

That UDID is the iPhone 17 runtime on this Mac.
