#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift test --package-path "$ROOT/Packages/WBCore" -Xswiftc -warnings-as-errors
swift test --package-path "$ROOT/Packages/WBProcess" -Xswiftc -warnings-as-errors
swift test --package-path "$ROOT/Packages/WBDevices" -Xswiftc -warnings-as-errors
swift test --package-path "$ROOT/Packages/WBMirror" -Xswiftc -warnings-as-errors
swift test --package-path "$ROOT/Packages/WBInspect" -Xswiftc -warnings-as-errors
swift test --package-path "$ROOT/Packages/WBFlutter" -Xswiftc -warnings-as-errors
swift test --package-path "$ROOT/Packages/WBNetwork" -Xswiftc -warnings-as-errors
swift test --package-path "$ROOT/Packages/WBVision" -Xswiftc -warnings-as-errors
swift test --package-path "$ROOT/Packages/WBSnapshot" -Xswiftc -warnings-as-errors
swift build --package-path "$ROOT/Tools/wbctl" -Xswiftc -warnings-as-errors
swift build --package-path "$ROOT/App" -Xswiftc -warnings-as-errors
