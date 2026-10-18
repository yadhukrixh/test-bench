#!/usr/bin/env python3
"""Launch flutter run --machine on a pty and keep it until killed."""

from __future__ import annotations

import json
import os
import pty
import select
import time
from pathlib import Path

ROOT = Path("/Users/yadhu/Documents/qa-bench/Spikes/spike_fixture")
URI = Path("/Users/yadhu/Documents/qa-bench/Spikes/results/vm_uri.txt")
FLUTTER = os.path.expanduser("~/develop/flutter/bin/flutter")


def main() -> None:
    master, slave = pty.openpty()
    env = os.environ.copy()
    env["PATH"] = os.path.expanduser("~/develop/flutter/bin") + ":" + env.get("PATH", "")
    env["ANDROID_SDK_ROOT"] = os.path.expanduser("~/Library/Android/sdk")
    env["ANDROID_HOME"] = env["ANDROID_SDK_ROOT"]
    os.dup2(slave, 0)
    os.dup2(slave, 1)
    os.dup2(slave, 2)
    os.close(slave)
    pid = os.fork()
    if pid == 0:
        os.execvpe(FLUTTER, [FLUTTER, "run", "--machine", "-d", "emulator-5554"], env)
    buffer = ""
    while True:
        ready, _, _ = select.select([master], [], [], 1)
        if not ready:
            continue
        data = os.read(master, 65536)
        if not data:
            break
        buffer += data.decode("utf-8", "replace")
        while "\n" in buffer:
            line, buffer = buffer.split("\n", 1)
            line = line.strip()
            if not line.startswith("["):
                continue
            try:
                messages = json.loads(line)
            except json.JSONDecodeError:
                continue
            for message in messages if isinstance(messages, list) else []:
                if message.get("event") == "app.debugPort" and not URI.exists():
                    URI.write_text(message["params"]["wsUri"] + "\n")
        # Stay alive with the child. The parent of this script is the shell.


if __name__ == "__main__":
    os.chdir(ROOT)
    main()
