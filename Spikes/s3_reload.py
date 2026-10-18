#!/usr/bin/env python3
"""Drive flutter run --machine through a pty and record hot reload/restart."""

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
OUT = Path("/Users/yadhu/Documents/qa-bench/Spikes/results/s3_reload.json")
FLUTTER = os.path.expanduser("~/develop/flutter/bin/flutter")


def read_available(fd: int, deadline: float) -> bytes:
    chunks = []
    while time.time() < deadline:
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
    return b"".join(chunks)


async def isolate_id(ws_uri: str) -> str:
    async with websockets.connect(ws_uri, max_size=4 * 1024 * 1024) as ws:
        await ws.send(json.dumps({"jsonrpc": "2.0", "id": "1", "method": "getVM"}))
        while True:
            message = json.loads(await ws.recv())
            if message.get("id") == "1":
                isolates = message["result"]["isolates"]
                return isolates[0]["id"] if isolates else ""


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
    buffer = ""
    events = []
    ws_uri = None
    app_id = None
    started = time.time()
    report: dict = {"events": []}
    try:
        while time.time() - started < 240 and ws_uri is None:
            chunk = read_available(master, time.time() + 2)
            if not chunk and proc.poll() is not None:
                break
            buffer += chunk.decode("utf-8", "replace")
            while "\n" in buffer:
                line, buffer = buffer.split("\n", 1)
                line = line.strip()
                if not line.startswith("["):
                    continue
                try:
                    messages = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(messages, list):
                    continue
                for message in messages:
                    event = message.get("event")
                    if event in {"app.start", "app.debugPort", "app.started", "app.devTools", "app.stop"}:
                        events.append({"t": round(time.time() - started, 2), "event": event, "params": message.get("params")})
                    if event == "app.start":
                        app_id = message["params"]["appId"]
                    if event == "app.debugPort":
                        ws_uri = message["params"].get("wsUri")
        report["machineEvents"] = events
        report["wsUriPresent"] = bool(ws_uri)
        report["appId"] = app_id
        if not ws_uri or not app_id:
            report["error"] = "debug port did not arrive"
            report["bufferTail"] = buffer[-1500:]
            return

        before = asyncio.run(isolate_id(ws_uri))
        report["isolateBefore"] = before

        def send(method: str, params: dict, message_id: int) -> None:
            payload = json.dumps([{"id": message_id, "method": method, "params": params}]) + "\n"
            os.write(master, payload.encode())

        send("app.restart", {"appId": app_id, "fullRestart": False, "pause": False, "debounce": False}, 1)
        time.sleep(3)
        chunk = read_available(master, time.time() + 8)
        report["afterReloadTail"] = chunk.decode("utf-8", "replace")[-2000:]
        report["isolateAfterHotReload"] = asyncio.run(isolate_id(ws_uri))

        send("app.restart", {"appId": app_id, "fullRestart": True, "pause": False, "debounce": False}, 2)
        # Hot restart replaces the VM service. Wait for a new debug port.
        new_uri = None
        deadline = time.time() + 90
        pending = chunk.decode("utf-8", "replace")
        while time.time() < deadline and new_uri is None:
            more = read_available(master, time.time() + 2)
            pending += more.decode("utf-8", "replace")
            while "\n" in pending:
                line, pending = pending.split("\n", 1)
                line = line.strip()
                if not line.startswith("["):
                    continue
                try:
                    messages = json.loads(line)
                except json.JSONDecodeError:
                    continue
                for message in messages if isinstance(messages, list) else []:
                    if message.get("event") == "app.debugPort":
                        new_uri = message["params"].get("wsUri")
                        report.setdefault("restartEvents", []).append(message["params"])
        report["wsUriAfterRestart"] = new_uri
        if new_uri:
            report["isolateAfterHotRestart"] = asyncio.run(isolate_id(new_uri))
        send("app.stop", {"appId": app_id}, 3)
        time.sleep(1)
    finally:
        OUT.write_text(json.dumps(report, indent=2))
        print(OUT.read_text())
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        os.close(master)


if __name__ == "__main__":
    main()
