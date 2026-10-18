#!/usr/bin/env python3
"""Phase 0 spike S3: call the live Dart VM service and the Flutter inspector."""

from __future__ import annotations

import argparse
import asyncio
import json
import sys

import websockets


async def call(ws, method: str, params: dict | None = None) -> dict:
    call.seq += 1
    message_id = str(call.seq)
    payload = {"jsonrpc": "2.0", "id": message_id, "method": method}
    if params is not None:
        payload["params"] = params
    await ws.send(json.dumps(payload))
    while True:
        raw = await asyncio.wait_for(ws.recv(), timeout=30)
        message = json.loads(raw)
        if message.get("id") == message_id:
            return message


call.seq = 0


def shorten(value, limit: int = 1500) -> object:
    text = json.dumps(value, ensure_ascii=False)
    if len(text) <= limit:
        return value
    return {"truncated": True, "chars": len(text), "head": text[:limit]}


async def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ws", required=True)
    parser.add_argument("--pub-root", required=True)
    args = parser.parse_args()

    async with websockets.connect(args.ws, max_size=16 * 1024 * 1024) as ws:
        vm = await call(ws, "getVM")
        result = vm.get("result", vm)
        isolates = result.get("isolates", []) if isinstance(result, dict) else []
        report: dict = {
            "vmType": result.get("type") if isinstance(result, dict) else None,
            "version": result.get("version") if isinstance(result, dict) else None,
            "isolateCount": len(isolates),
            "isolates": [],
        }
        inspector_id = None
        for isolate in isolates:
            detail = await call(ws, "getIsolate", {"isolateId": isolate["id"]})
            info = detail.get("result", {})
            rpcs = info.get("extensionRPCs", [])
            report["isolates"].append(
                {
                    "id": isolate["id"],
                    "name": isolate.get("name"),
                    "extensionCount": len(rpcs),
                    "hasInspector": any(name.startswith("ext.flutter.inspector.") for name in rpcs),
                    "hasHttp": any(name.startswith("ext.dart.io.http") for name in rpcs),
                    "inspectorRpcs": [name for name in rpcs if "inspector" in name or "flutter" in name],
                    "httpRpcs": [name for name in rpcs if name.startswith("ext.dart.io.")],
                }
            )
            if inspector_id is None and any(
                name == "ext.flutter.inspector.getRootWidgetSummaryTree" for name in rpcs
            ):
                inspector_id = isolate["id"]

        if inspector_id is None:
            print(json.dumps(report, indent=2))
            return 1

        report["inspectorIsolate"] = inspector_id
        ready = await call(
            ws,
            "ext.flutter.inspector.isWidgetTreeReady",
            {"isolateId": inspector_id},
        )
        tracked = await call(
            ws,
            "ext.flutter.inspector.isWidgetCreationTracked",
            {"isolateId": inspector_id},
        )
        roots = await call(
            ws,
            "ext.flutter.inspector.addPubRootDirectories",
            {"isolateId": inspector_id, "arg0": args.pub_root},
        )
        tree = await call(
            ws,
            "ext.flutter.inspector.getRootWidgetSummaryTree",
            {"isolateId": inspector_id, "objectGroup": "spike-1"},
        )
        show = await call(
            ws,
            "ext.flutter.inspector.show",
            {"isolateId": inspector_id, "enabled": "true"},
        )
        report["isWidgetTreeReady"] = ready.get("result")
        report["isWidgetCreationTracked"] = tracked.get("result")
        report["addPubRootDirectories"] = roots.get("result", roots.get("error"))
        report["show"] = show.get("result", show.get("error"))
        tree_result = tree.get("result", tree.get("error"))
        report["tree"] = shorten(tree_result)
        if isinstance(tree_result, dict) and "result" in tree_result:
            encoded = json.dumps(tree_result["result"])
            report["treeChars"] = len(encoded)
            report["treeEmpty"] = tree_result["result"] in (None, {}, [])

        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 0


if __name__ == "__main__":
    try:
        raise SystemExit(asyncio.run(main()))
    except Exception as exc:  # spike: show the failure instead of a traceback-only exit
        print(json.dumps({"error": f"{type(exc).__name__}: {exc}"}), file=sys.stderr)
        raise
