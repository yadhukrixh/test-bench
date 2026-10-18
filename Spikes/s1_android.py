#!/usr/bin/env python3
"""Phase 0 spike S1: Android emulator gRPC frames and input.

Throwaway. Talks to a headless emulator already listening on --port.
Records measurements as JSON on stdout and under Spikes/results/.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import grpc
from google.protobuf import empty_pb2

GEN = Path(__file__).resolve().parent / "gen"
sys.path.insert(0, str(GEN))

import emulator_controller_pb2 as pb  # noqa: E402
import emulator_controller_pb2_grpc as pbg  # noqa: E402

RESULTS = Path(__file__).resolve().parent / "results"


def stub(port: int) -> pbg.EmulatorControllerStub:
    # A full 1080x2400 RGBA frame is 10,368,000 bytes. The default 4 MiB
    # receive limit rejects it (observed: 10368035 vs 4194304).
    channel = grpc.insecure_channel(
        f"127.0.0.1:{port}",
        options=[("grpc.max_receive_message_length", 32 * 1024 * 1024)],
    )
    return pbg.EmulatorControllerStub(channel)


def call_status(s: pbg.EmulatorControllerStub) -> dict:
    status = s.getStatus(empty_pb2.Empty(), timeout=10)
    return {
        "version": status.version,
        "uptime_ms": status.uptime,
        "booted": status.booted,
        "heartbeat": status.heartbeat,
        "guest": dict(status.guestConfig),
    }


def measure_frames(s: pbg.EmulatorControllerStub, seconds: float, width: int, height: int) -> dict:
    fmt = pb.ImageFormat(format=pb.ImageFormat.RGBA8888, width=width, height=height)
    started = time.perf_counter()
    deadline = started + seconds
    count = 0
    empty = 0
    bytes_total = 0
    seqs: list[int] = []
    first_size = None
    gaps = 0
    prev_seq = None
    host_dts: list[float] = []
    last_host = None
    try:
        # The timeout ends the RPC. A static display emits one frame and then
        # waits, so a long timeout would block until the deadline.
        stream = s.streamScreenshot(fmt, timeout=seconds)
        for image in stream:
            now = time.perf_counter()
            if now > deadline and count > 0:
                break
            payload = image.image
            seq = image.seq
            seqs.append(seq)
            if prev_seq is not None and seq > prev_seq + 1:
                gaps += seq - prev_seq - 1
            prev_seq = seq
            if last_host is not None:
                host_dts.append(now - last_host)
            last_host = now
            if len(payload) == 0:
                empty += 1
            else:
                bytes_total += len(payload)
                if first_size is None:
                    first_size = {
                        "width": image.format.width,
                        "height": image.format.height,
                        "bytes": len(payload),
                        "rotation": int(image.format.rotation.rotation),
                    }
            count += 1
    except grpc.RpcError as exc:
        if exc.code() != grpc.StatusCode.DEADLINE_EXCEEDED or count == 0:
            return {"error": f"{exc.code()}: {exc.details()}", "frames": count}

    elapsed = time.perf_counter() - started
    host_dts.sort()

    def pct(p: float) -> float | None:
        if not host_dts:
            return None
        index = min(len(host_dts) - 1, int(p * len(host_dts)))
        return round(host_dts[index] * 1000, 2)

    return {
        "requested": {"width": width, "height": height, "format": "RGBA8888"},
        "seconds": round(elapsed, 3),
        "frames": count,
        "empty_frames": empty,
        "fps": round(count / elapsed, 2) if elapsed else 0,
        "dropped_seq_gaps": gaps,
        "first_frame": first_size,
        "host_interval_ms": {"p50": pct(0.50), "p95": pct(0.95)},
        "megabytes": round(bytes_total / (1024 * 1024), 1),
    }


def tap(s: pbg.EmulatorControllerStub, x: int, y: int, identifier: int = 1) -> None:
    s.sendTouch(
        pb.TouchEvent(
            touches=[pb.Touch(x=x, y=y, identifier=identifier, pressure=1)],
            display=0,
        ),
        timeout=5,
    )
    time.sleep(0.05)
    s.sendTouch(
        pb.TouchEvent(
            touches=[pb.Touch(x=x, y=y, identifier=identifier, pressure=0)],
            display=0,
        ),
        timeout=5,
    )


def swipe(
    s: pbg.EmulatorControllerStub,
    x0: int,
    y0: int,
    x1: int,
    y1: int,
    duration_s: float,
) -> int:
    steps = max(2, int(duration_s * 60))
    identifier = 2
    for i in range(steps + 1):
        t = i / steps
        x = int(x0 + (x1 - x0) * t)
        y = int(y0 + (y1 - y0) * t)
        s.sendTouch(
            pb.TouchEvent(
                touches=[pb.Touch(x=x, y=y, identifier=identifier, pressure=1)],
                display=0,
            ),
            timeout=5,
        )
        time.sleep(duration_s / steps)
    s.sendTouch(
        pb.TouchEvent(
            touches=[pb.Touch(x=x1, y=y1, identifier=identifier, pressure=0)],
            display=0,
        ),
        timeout=5,
    )
    return steps


def send_key(s: pbg.EmulatorControllerStub, key: str) -> dict:
    try:
        s.sendKey(
            pb.KeyboardEvent(key=key, eventType=pb.KeyboardEvent.keypress),
            timeout=5,
        )
        return {"key": key, "ok": True}
    except grpc.RpcError as exc:
        return {"key": key, "ok": False, "error": f"{exc.code()}: {exc.details()}"}


def clipboard_roundtrip(s: pbg.EmulatorControllerStub, text: str) -> dict:
    s.setClipboard(pb.ClipData(text=text), timeout=5)
    time.sleep(0.2)
    got = s.getClipboard(empty_pb2.Empty(), timeout=5)
    return {"sent": text, "got": got.text, "match": got.text == text}


def one_frame(s: pbg.EmulatorControllerStub, width: int = 0, height: int = 0) -> pb.Image:
    fmt = pb.ImageFormat(format=pb.ImageFormat.RGBA8888, width=width, height=height)
    return s.getScreenshot(fmt, timeout=20)


def pixel(image: pb.Image, x: int, y: int) -> tuple[int, int, int, int] | None:
    width = image.format.width
    height = image.format.height
    raw = image.image
    if width == 0 or height == 0 or len(raw) < width * height * 4:
        return None
    # Proto: pixels are left to right and bottom up.
    row = height - 1 - y
    if row < 0 or x < 0 or x >= width or y >= height:
        return None
    index = (row * width + x) * 4
    r, g, b, a = raw[index : index + 4]
    return (r, g, b, a)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8554)
    parser.add_argument(
        "--mode",
        choices=["status", "frames", "input", "clipboard", "sample-pixel"],
        required=True,
    )
    parser.add_argument("--seconds", type=float, default=8)
    parser.add_argument("--width", type=int, default=0)
    parser.add_argument("--height", type=int, default=0)
    parser.add_argument("--text", default="ログイン")
    args = parser.parse_args()

    RESULTS.mkdir(parents=True, exist_ok=True)
    s = stub(args.port)
    try:
        if args.mode == "status":
            report = call_status(s)
        elif args.mode == "frames":
            report = measure_frames(s, args.seconds, args.width, args.height)
        elif args.mode == "clipboard":
            report = {
                "japanese": clipboard_roundtrip(s, args.text),
                "ascii": clipboard_roundtrip(s, "hello-qa"),
            }
        elif args.mode == "input":
            report = {
                "tap": {"x": 540, "y": 1200},
                "swipe_steps": swipe(s, 540, 1800, 540, 600, 0.4),
                "keys": [send_key(s, "GoBack"), send_key(s, "GoHome")],
            }
            tap(s, 540, 1200)
        elif args.mode == "sample-pixel":
            image = one_frame(s)
            center_x = image.format.width // 2
            center_y = image.format.height // 2
            report = {
                "width": image.format.width,
                "height": image.format.height,
                "bytes": len(image.image),
                "center": pixel(image, center_x, center_y),
                "rotation": int(image.format.rotation.rotation),
            }
        else:
            raise AssertionError(args.mode)
    except grpc.RpcError as exc:
        report = {"error": f"{exc.code()}: {exc.details()}"}
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 1

    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
