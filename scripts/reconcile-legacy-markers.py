#!/usr/bin/env python3
"""Conservatively reconcile legacy callback/announced markers.

Dry-run by default. Successful delivery evidence becomes a generic sent receipt.
Unproven .announced markers are quarantined and never trigger a resend.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
from pathlib import Path
import subprocess
import sys


def delivery_succeeded(path: Path) -> bool:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return False
    status = data.get("deliveryStatus") or {}
    if status.get("succeeded") is True or status.get("status") == "sent":
        return True
    return data.get("ok") is True and bool(data.get("messageId"))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--registry-dir", default=os.environ.get("CC_REGISTRY_DIR", "/tmp/claude-subagent-registry"))
    parser.add_argument("--hooks-dir", default=os.environ.get("CC_HOOKS_DIR", "/tmp/claude-subagent-hooks"))
    parser.add_argument("--state-tool", default=str(Path(__file__).with_name("cc-state.py")))
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--report", default="")
    args = parser.parse_args()

    registry_dir = Path(args.registry_dir)
    hooks_dir = Path(args.hooks_dir)
    report: list[dict[str, object]] = []
    for registry_name in sorted(glob.glob(str(registry_dir / "*.json"))):
        registry = Path(registry_name)
        task_id = registry.stem
        announced = registry_dir / f"{task_id}.announced"
        zara_marker = hooks_dir / f"{task_id}.zara-notified.ok"
        generic_marker = hooks_dir / f"{task_id}.callback-sent"
        candidates = [
            hooks_dir / f"{task_id}.zara-agent.json",
            hooks_dir / f"{task_id}.notify.out",
            hooks_dir / f"{task_id}.sweeper-receipt.json",
            hooks_dir / f"{task_id}.direct-receipt.json",
        ]
        evidence = next((item for item in candidates if item.exists() and delivery_succeeded(item)), None)
        if not announced.exists() and not zara_marker.exists() and not generic_marker.exists():
            continue
        if generic_marker.exists() or evidence:
            state = "sent"
            marker = str(generic_marker if generic_marker.exists() else zara_marker if zara_marker.exists() else announced)
        else:
            state = "quarantined"
            marker = str(announced if announced.exists() else zara_marker)
        item = {"task_id": task_id, "state": state, "marker": marker, "evidence": str(evidence or ""), "applied": args.apply}
        report.append(item)
        if args.apply:
            command = [sys.executable, args.state_tool, "legacy-reconcile", "--registry", str(registry), "--state", state, "--marker", marker]
            if evidence:
                command += ["--receipt-file", str(evidence)]
            subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
            if state == "sent":
                generic_marker.touch(exist_ok=True)
                announced.touch(exist_ok=True)
    output = {"mode": "apply" if args.apply else "dry-run", "count": len(report), "items": report}
    rendered = json.dumps(output, indent=2, sort_keys=True)
    print(rendered)
    if args.report:
        Path(args.report).write_text(rendered + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
