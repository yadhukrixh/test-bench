# Phase 0 demo

This demo repeats the checks that passed. It needs the `Pixel_8` AVD, Flutter 3.41.8, and the Python environment in `Spikes/.venv`. It boots an emulator. Shut it down when finished.

1. Start the emulator and wait until `adb -s emulator-5554 shell getprop sys.boot_completed` prints `1`:

```text
emulator -avd Pixel_8 -port 5554 -grpc 8554 -no-window -no-audio -no-boot-anim
```

2. Frames and a screenshot pixel:

```text
Spikes/.venv/bin/python Spikes/s1_android.py --mode status
Spikes/.venv/bin/python Spikes/s1_android.py --mode sample-pixel
Spikes/.venv/bin/python Spikes/s1_android.py --mode frames --seconds 3
```

Expect `booted: true` and a 1080×2400 frame. A still screen returns about one frame.

3. Flutter, on a terminal so the machine events flush:

```text
cd Spikes/spike_fixture
flutter run --machine -d emulator-5554
```

Expect `app.debugPort` with a `wsUri`, then the white touch screen.

4. Tap the center with `Spikes/s1_android.py` touch calls, or tap in any gRPC client at `(540, 1200)`. The screen turns red and the label reports a point within 1 px of `(540, 1200)`.

5. Stop Flutter with `app.stop`, then `adb -s emulator-5554 emu kill`.

iOS, proxy, and WebView are not part of this demo. Their results are in `docs/SPIKES.md`.
