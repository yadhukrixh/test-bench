# Phase 1 demo

Recorded 2026-10-14 on this Mac after `scripts/bundle-app.sh`.

## What you can do

1. Open `build/QA Workbench.app`.
2. Accept the authorized-use notice.
3. Open Doctor. On a normal PATH every required tool passes. `idb` and `mitmdump` warn, and that is accurate.
4. Choose iPhone 17 and press Boot, then Stop. The same path from the terminal:

```bash
Tools/wbctl/.build/debug/wbctl devices boot --id ios:15AB8309-1B82-4862-BAE8-AEA1F118A0AB
Tools/wbctl/.build/debug/wbctl devices stop --id ios:15AB8309-1B82-4862-BAE8-AEA1F118A0AB
```

`simctl list` showed that simulator Booted, then Shutdown.

5. Choose Pixel_8 and press Boot. The emulator starts headless (`-no-window`). The frame in the window stays blank. Stop shuts it down. A measured run printed `android:Pixel_8 is booted. emulator-5554, gRPC 8554`, and after Stop there was no `qemu-system` process.

The Tree, Snapshots, Properties, Network, Text, and Console panes are empty on purpose.
