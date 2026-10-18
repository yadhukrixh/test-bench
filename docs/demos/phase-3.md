# Phase 3 demo

The left dock shows the UiAutomator tree of a booted Android emulator. Selecting a node fills Properties and draws a box on the picture. Inspect mode selects instead of tapping. An APK already on the emulator can be chosen from `/sdcard`, `/sdcard/Download`, `/sdcard/Downloads`, `/data/local/tmp`, and the matching `/storage/emulated/0` folders.

iOS still has no tree. idb is not installed. Snapshots, Network, Text, and Console still say they are not in this version.

## What was run on 2026-10-14

`Pixel_8` was already booted at `emulator-5554`. With `WB_ADB_SERIAL=emulator-5554`, the live dump test finished in 2.479 seconds.

`adb exec-out uiautomator dump /dev/tty` returned 53,272 characters, the product trailer `UI hierchary dumped to: /dev/tty`, a root of `[0,0][1080,2400]`, and labelled tiles including Wi-Fi and Bluetooth.

`adb push` put the Flutter fixture APK at `/data/local/tmp/app-debug.apk`. `ls -1 /data/local/tmp` listed that file. `adb pull` of that path started with `PK\x03\x04`. `adb install -r -t` of the pulled file printed `Success`.

The emulator was left running because the workbench window had it booted.

## How to see it

```bash
scripts/bundle-app.sh
open "build/QA Workbench.app"
```

Boot `Pixel_8` if it is not already up. The tree fills on its own. Click a row, or turn on Inspect and click the picture. Properties lists the attributes from the dump. Refresh asks for another dump.

Under the picture, On the emulator lists APKs found in the folders above. Refresh list reads them again. Install from emulator copies the chosen file off the device and runs `adb install -r -t`.
