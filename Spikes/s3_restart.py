#!/usr/bin/env python3
"""Record isolate ids across hot reload and hot restart."""

from __future__ import annotations

import json
import os
import pty
import select
import subprocess
import time
from pathlib import Path

import websockets

ROOT = Path("/Users/yadhu/Documents/qa-bench/Spikes/spike_fixture")
OUT = Path("/Users/yadhu/Documents/qa-bench/Spikes/results/s3_restart.json")
FLUTTER = os.path.expanduser("~/develop/flutter/bin/flutter")
MAIN = ROOT / "lib" / "main.dart"


def pump(fd: int, seconds: float) -> str:
    end = time.time() + seconds
    chunks: list[bytes] = []
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if not ready:
            continue
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        chunks.append(data)
    return b"".join(chunks).decode("utf-8", "replace")


def parse_events(text: str) -> list[dict]:
    found = []
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("["):
            continue
        try:
            messages = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(messages, list):
            found.extend(messages)
    return found


async def isolate_id(ws_uri: str) -> str:
    async with websockets.connect(ws_uri, max_size=4 * 1024 * 1024) as ws:
        await ws.send(json.dumps({"jsonrpc": "2.0", "id": "1", "method": "getVM"}))
        while True:
            message = json.loads(await ws.recv())
            if message.get("id") == "1":
                isolates = message["result"]["isolates"]
                return isolates[0]["id"]


def main() -> None:
    import asyncio

    master, slave = pty.openpty()
    env = os.environ.copy()
    env["PATH"] = os.path.expanduser("~/develop/flutter/bin") + ":" + env.get("PATH", "")
    env["ANDROID_SDK_ROOT"] = os.path.expanduser("~/Library/Android/sdk")
    env["ANDROID_HOME"] = env["ANDROID_SDK_ROOT"]
    proc = subprocess.Popen(
        [FLUTTER, "run", "--machine", "-d", "emulator-5554"],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        cwd=ROOT,
        env=env,
        close_fds=True,
    )
    os.close(slave)
    report: dict = {}
    original = MAIN.read_text()
    try:
        text = ""
        ws_uri = None
        app_id = None
        deadline = time.time() + 180
        while time.time() < deadline and ws_uri is None:
            text += pump(master, 1)
            for message in parse_events(text):
                if message.get("event") == "app.start":
                    app_id = message["params"]["appId"]
                if message.get("event") == "app.debugPort":
                    ws_uri = message["params"].get("wsUri")
        report["appId"] = app_id
        report["wsUri"] = ws_uri
        if not ws_uri or not app_id:
            report["error"] = "no debug port"
            return
        report["isolateBefore"] = asyncio.run(isolate_id(ws_uri))
        MAIN.write_text(original.replace("Spike Fixture", "Spike Fixture reload", 1))
        payload = json.dumps([{
            "id": 1,
            "method": "app.restart",
            "params": {"appId": app_id, "fullRestart": False, "pause": False, "debounce": False},
        }]) + "\n"
        os.write(master, payload.encode())
        reload_text = pump(master, 8)
        report["reloadEvents"] = [
            {"event": m.get("event"), "id": m.get("id"), "result": m.get("result"), "error": m.get("error")}
            for m in parse_events(reload_text)
            if m.get("event") in {"app.progress", "app.debugPort", "app.log"} or "id" in m
        ]
        report["isolateAfterHotReload"] = asyncio.run(isolate_id(ws_uri))
        payload = json.dumps([{
            "id": 2,
            "method": "app.restart",
            "params": {"appId": app_id, "fullRestart": True, "pause": False, "debounce": False},
        }]) + "\n"
        os.write(master, payload.encode())
        restart_text = pump(master, 25)
        report["restartEvents"] = [
            {"event": m.get("event"), "id": m.get("id"), "result": m.get("result"), "error": m.get("error"), "params": m.get("params") if m.get("event") == "app.debugPort" else None}
            for m in parse_events(restart_text)
        ]
        new_uri = ws_uri
        for message in parse_events(restart_text):
            if message.get("event") == "app.debugPort":
                new_uri = message["params"].get("wsUri")
        report["wsUriAfterRestart"] = new_uri
        try:
            report["isolateAfterHotRestart"] = asyncio.run(isolate_id(new_uri))
        except Exception as exc:
            report["isolateAfterHotRestartError"] = f"{type(exc).__name__}: {exc}"
    finally:
        MAIN.write_text(original)
        OUT.write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2)[:8000])
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        os.close(master)


if __name__ == "__main__":
    main()
