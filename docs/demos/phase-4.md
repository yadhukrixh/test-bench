# Phase 4 demo

The Device tab can run a Flutter project with `flutter run --machine` on a pseudo-terminal. Console shows the machine events. Hot reload and hot restart send `app.restart`. Stop sends `app.stop`.

An APK from this Mac, from an `http` or `https` address, or from emulator storage is installed and then opened. Download uses curl. Launch uses the launchable activity from `aapt dump badging` and `adb shell am start`.

iOS still has no tree and no taps. Snapshots, Network, and Text still say they are not in this version.

## What was run on 2026-10-14

WBFlutter unit tests parsed `app.debugPort` (`port`, `wsUri`, `baseUri`), encoded `app.restart` with `fullRestart`, `pause`, and `debounce`, encoded `app.stop`, and recognized a folder with `pubspec.yaml`. A PTY test in WBProcess ran `/bin/echo` and read `pty-ok`.

`Pixel_8` was already booted at `emulator-5554`. `aapt dump badging` of `Spikes/spike_fixture/build/app/outputs/flutter-apk/app-debug.apk` reported package `com.qaworkbench.spike_fixture` and launchable activity `com.qaworkbench.spike_fixture.MainActivity`. `curl -L --fail` downloaded that file from `http://127.0.0.1`. `adb install -r -t` printed `Success`. `adb shell am start -n com.qaworkbench.spike_fixture/com.qaworkbench.spike_fixture.MainActivity` left `mCurrentFocus` on that activity.

`flutter run --machine` was not started in this check. It needs a real terminal, which the app opens, and it is heavy on 16 GB with the emulator already up.

## How to see it

```bash
scripts/bundle-app.sh
open "build/QA Workbench.app"
```

Boot `Pixel_8` if it is not already up. Under the picture, paste a direct APK address and press Download, install, and run, or choose a file, or pick an APK already on the emulator.

On the Device tab, Choose project…, then Run. The Console tab prints machine output. Hot reload and Hot restart work after `app.debugPort` appears.
