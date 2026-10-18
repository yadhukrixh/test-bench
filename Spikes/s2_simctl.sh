#!/bin/bash
# Phase 0 spike S2, simctl screenshot polling. The simulator UDID is $1.
set -u
UDID="$1"
OUT="/Users/yadhu/Documents/qa-bench/Spikes/results/s2_simctl"
mkdir -p "$OUT"
echo "describe"
xcrun simctl list devices | head -5 >/dev/null
# one screenshot timing
START=$(python3 -c 'import time; print(time.perf_counter())')
xcrun simctl io "$UDID" screenshot "$OUT/one.png"
END=$(python3 -c 'import time; print(time.perf_counter())')
python3 - <<PY
import time
start = float("$START")
end = float("$END")
print("single_screenshot_ms", round((end-start)*1000, 1))
PY
# poll for 5 seconds
python3 - <<PY
import subprocess, time
udid = "$UDID"
out = "$OUT"
count = 0
empty = 0
started = time.perf_counter()
deadline = started + 5
while time.perf_counter() < deadline:
    path = f"{out}/frame_{count}.png"
    proc = subprocess.run(["xcrun", "simctl", "io", udid, "screenshot", path], capture_output=True)
    if proc.returncode != 0:
        print("error", proc.stderr.decode()[-200:])
        break
    count += 1
elapsed = time.perf_counter() - started
print("frames", count, "seconds", round(elapsed, 2), "fps", round(count/elapsed, 2))
PY
file "$OUT/one.png"
sips -g pixelWidth -g pixelHeight "$OUT/one.png"
