#!/usr/bin/env python3
"""Phase 0 spike S8: Android WebView / Chrome DevTools sockets.

Throwaway. Talks to a booted emulator. Writes JSON under Spikes/results/.
Does not invent sockets. Only records what adb and HTTP actually return.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

RESULTS = Path(__file__).resolve().parent / "results"


def adb(serial: str, *args: str, timeout: int = 20) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["adb", "-s", serial, *args],
        text=True,
        capture_output=True,
        timeout=timeout,
    )


def unix_devtools(serial: str) -> list[str]:
    out = adb(serial, "shell", "cat", "/proc/net/unix").stdout
    names = []
    for line in out.splitlines():
        if "@" not in line:
            continue
        name = line.rsplit("@", 1)[-1].strip()
        if "devtools" in name or "chrome_devtools" in name or "webview_devtools" in name:
            names.append(name)
    return names


def dump_buttons(serial: str) -> list[dict]:
    raw = adb(serial, "exec-out", "uiautomator", "dump", "/dev/tty", timeout=30).stdout
    found = []
    for match in re.finditer(
        r'text="([^"]*)"[^>]*resource-id="([^"]*)"[^>]*class="([^"]+)"[^>]*'
        r'clickable="([^"]+)"[^>]*bounds="\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]"',
        raw,
    ):
        text, rid, cls, click, left, top, right, bottom = match.groups()
        if click != "true" and not text:
            continue
        found.append(
            {
                "text": text,
                "id": rid,
                "class": cls,
                "clickable": click == "true",
                "bounds": [int(left), int(top), int(right), int(bottom)],
            }
        )
    return found


def tap_bounds(serial: str, bounds: list[int]) -> None:
    x = (bounds[0] + bounds[2]) // 2
    y = (bounds[1] + bounds[3]) // 2
    adb(serial, "shell", "input", "tap", str(x), str(y))


def resumed(serial: str) -> str:
    out = adb(serial, "shell", "dumpsys", "activity", "activities").stdout
    for line in out.splitlines():
        if "topResumedActivity" in line:
            return line.strip()
    return ""


def try_json(url: str) -> dict | list | str | None:
    try:
        with urllib.request.urlopen(url, timeout=3) as response:
            body = response.read()
            try:
                return json.loads(body.decode("utf-8"))
            except json.JSONDecodeError:
                return body.decode("utf-8", errors="replace")
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        return {"error": str(error)}


def cdp_evaluate(ws_url: str, expression: str) -> dict:
    try:
        import websocket  # type: ignore
    except ImportError:
        return {"error": "websocket-client not installed"}
    try:
        sock = websocket.create_connection(ws_url, timeout=5)
        sock.send(
            json.dumps(
                {
                    "id": 1,
                    "method": "Runtime.evaluate",
                    "params": {"expression": expression, "returnByValue": True},
                }
            )
        )
        raw = sock.recv()
        sock.close()
        return json.loads(raw)
    except Exception as error:  # noqa: BLE001 — spike records the failure
        return {"error": str(error)}


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def probe_socket(serial: str, name: str) -> dict:
    port = free_port()
    adb(serial, "forward", "--remove", f"tcp:{port}")
    forwarded = adb(serial, "forward", f"tcp:{port}", f"localabstract:{name}")
    result = {
        "name": name,
        "port": port,
        "forward_status": forwarded.returncode,
        "forward_err": (forwarded.stderr or "").strip(),
    }
    if forwarded.returncode != 0:
        return result
    result["version"] = try_json(f"http://127.0.0.1:{port}/json/version")
    listing = try_json(f"http://127.0.0.1:{port}/json/list")
    result["list"] = listing
    if isinstance(listing, list) and listing:
        first = listing[0]
        ws = first.get("webSocketDebuggerUrl") if isinstance(first, dict) else None
        if isinstance(ws, str) and ws.startswith("ws"):
            result["title"] = cdp_evaluate(ws, "document.title")
            result["href"] = cdp_evaluate(ws, "location.href")
    adb(serial, "forward", "--remove", f"tcp:{port}")
    return result


def dismiss_chrome_fre(serial: str) -> list[str]:
    steps = []
    for _ in range(6):
        activity = resumed(serial)
        buttons = dump_buttons(serial)
        labels = [item["text"] for item in buttons if item["text"]]
        steps.append(f"{activity} :: {labels}")
        wanted = None
        for item in buttons:
            text = item["text"].lower()
            rid = item["id"]
            if "signin_fre_dismiss_button" in rid or text in {
                "stay signed out",
                "no thanks",
                "not now",
                "skip",
                "use without an account",
                "got it",
                "accept & continue",
                "accept and continue",
            }:
                wanted = item
                break
        if wanted is None:
            break
        tap_bounds(serial, wanted["bounds"])
        time.sleep(2)
    return steps


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--serial", default="emulator-5554")
    args = parser.parse_args()
    serial = args.serial
    RESULTS.mkdir(parents=True, exist_ok=True)

    before = unix_devtools(serial)
    start = adb(
        serial,
        "shell",
        "am",
        "start",
        "-a",
        "android.intent.action.VIEW",
        "-d",
        "https://example.com",
        "-n",
        "com.android.chrome/com.google.android.apps.chrome.Main",
    )
    time.sleep(2)
    fre = dismiss_chrome_fre(serial)
    time.sleep(2)
    after_chrome = unix_devtools(serial)

    chrome_pid = adb(serial, "shell", "pidof", "com.android.chrome").stdout.strip()
    candidates = []
    for name in after_chrome:
        if name.startswith("stetho_"):
            continue
        candidates.append(name)
    if "chrome_devtools_remote" not in candidates:
        candidates.append("chrome_devtools_remote")
    if chrome_pid and f"chrome_devtools_remote_{chrome_pid}" not in candidates:
        candidates.append(f"chrome_devtools_remote_{chrome_pid}")

    probes = [probe_socket(serial, name) for name in candidates]

    record = {
        "serial": serial,
        "before": before,
        "start": {"status": start.returncode, "out": (start.stdout + start.stderr).strip()},
        "fre": fre,
        "activity": resumed(serial),
        "chrome_pid": chrome_pid,
        "after_chrome": after_chrome,
        "probes": probes,
        "simctl_inspect": "no inspect/safari/webkit verb in simctl help",
        "safaridriver": "/System/Cryptexes/App/usr/bin/safaridriver exists; WebDriver, not CDP",
    }
    path = RESULTS / "s8_webview.json"
    path.write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps(record, indent=2))
    print(f"wrote {path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
