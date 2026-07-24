#!/usr/bin/env python3
"""Atomic state and artifact verification for Claude delegate tasks."""
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import tempfile
from typing import Any

TERMINAL = {"done", "failed", "timeout", "cancelled", "incomplete"}
DECISIONS = {"continue", "switch", "blocked", "complete"}
CALLBACK_STATES = {"pending", "in_progress", "sent", "failed"}


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).astimezone().isoformat(timespec="seconds")


def parse_time(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    try:
        return dt.datetime.fromisoformat(value)
    except ValueError:
        return None


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def snapshot(path: Path) -> dict[str, Any]:
    try:
        stat = path.stat()
        if not path.is_file():
            return {"exists": True, "regular_file": False, "size": 0, "mtime_ns": stat.st_mtime_ns, "sha256": ""}
        return {
            "exists": True,
            "regular_file": True,
            "size": stat.st_size,
            "mtime_ns": stat.st_mtime_ns,
            "sha256": file_sha256(path),
        }
    except FileNotFoundError:
        return {"exists": False, "regular_file": False, "size": 0, "mtime_ns": 0, "sha256": ""}


def canonical(path: str, workdir: Path) -> Path:
    candidate = Path(path).expanduser()
    if not candidate.is_absolute():
        candidate = workdir / candidate
    return candidate.resolve(strict=False)


def contained(path: Path, roots: list[Path]) -> bool:
    for root in roots:
        try:
            path.relative_to(root)
            return True
        except ValueError:
            continue
    return False


def normalize_artifact(workdir_value: str, expected: str, allowed_values: list[str], min_bytes: int) -> dict[str, Any]:
    workdir = Path(workdir_value).expanduser().resolve(strict=False)
    roots = [canonical(value, workdir) for value in allowed_values] if allowed_values else [workdir]
    roots = list(dict.fromkeys(roots))
    result: dict[str, Any] = {
        "declared_path": expected,
        "canonical_path": "",
        "allowed_roots": [str(root) for root in roots],
        "min_bytes": min_bytes,
        "baseline": {"exists": False, "regular_file": False, "size": 0, "mtime_ns": 0, "sha256": ""},
        "verification": {"state": "not_required" if not expected else "pending"},
    }
    if not expected:
        return result
    path = canonical(expected, workdir)
    if not contained(path, roots):
        raise ValueError(f"expected_file escapes allowed roots: {path}")
    result["canonical_path"] = str(path)
    result["baseline"] = snapshot(path)
    return result


def atomic_dump(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, path)
        dir_fd = os.open(path.parent, os.O_DIRECTORY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temp_name)


@contextlib.contextmanager
def locked(registry: Path):
    lock_path = registry.with_suffix(registry.suffix + ".lock")
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a+", encoding="utf-8") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        yield
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def load(registry: Path) -> dict[str, Any]:
    with registry.open(encoding="utf-8") as handle:
        return json.load(handle)


def update(registry: Path, fn) -> dict[str, Any]:
    with locked(registry):
        data = load(registry)
        result = fn(data)
        data["updated_at"] = now()
        atomic_dump(registry, data)
        return result if result is not None else data


def nonnegative_int(value: str) -> int:
    try:
        number = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be an integer") from exc
    if number < 0:
        raise argparse.ArgumentTypeError("must be non-negative")
    return number


def positive_int(value: str) -> int:
    number = nonnegative_int(value)
    if number == 0:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def command_init(args: argparse.Namespace) -> None:
    registry = Path(args.registry)
    if registry.exists():
        raise SystemExit(f"registry already exists: {registry}")
    workdir = str(Path(args.workdir).expanduser().resolve(strict=False))
    artifact = normalize_artifact(workdir, args.expected_file, args.allowed_root, args.expect_min_bytes)
    owner = {
        "agent_id": args.owner_agent_id,
        "session_key": args.owner_session_key,
        "delivery": {"channel": args.delivery_channel, "target": args.delivery_target, "account": args.delivery_account},
    }
    stamp = now()
    data = {
        "schema_version": 2,
        "task_id": args.task_id,
        "status": "running",
        "session_id": args.session_id,
        "label": args.label,
        "workdir": workdir,
        "model": args.model,
        "budget": args.budget,
        "pid": "",
        "cost_usd": 0.0,
        "result_preview": "",
        "timeout_secs": args.timeout_secs,
        "notify_cmd": args.notify_cmd,
        "batch_id": args.batch_id,
        "resumed_from": args.resumed_from,
        "expected_file": args.expected_file,
        "expected_file_canonical": artifact["canonical_path"],
        "expect_min_bytes": args.expect_min_bytes,
        "allowed_artifact_roots": artifact["allowed_roots"],
        "artifact": artifact,
        "next_action": args.next_action,
        "continuation_mode": args.continuation_mode,
        "terminal_decision": {"state": "not_emitted", "requested": args.continuation_mode},
        "owner": owner,
        "callback": {"state": "pending", "attempts": 0, "lease_expires_at": "", "receipt": {}},
        "verified": False,
        "started_at": stamp,
        "updated_at": stamp,
    }
    with locked(registry):
        if registry.exists():
            raise SystemExit(f"registry already exists: {registry}")
        atomic_dump(registry, data)
    print(json.dumps(data, sort_keys=True))


def command_patch_pid(args: argparse.Namespace) -> None:
    registry = Path(args.registry)
    def patch(data: dict[str, Any]):
        if data.get("status") not in TERMINAL:
            data["pid"] = str(args.pid)
            return {"patched": True, "status": data.get("status")}
        return {"patched": False, "status": data.get("status")}
    print(json.dumps(update(registry, patch), sort_keys=True))


def verify_artifact(data: dict[str, Any]) -> dict[str, Any]:
    artifact = data.get("artifact") or normalize_artifact(
        data.get("workdir", ""), data.get("expected_file", ""), data.get("allowed_artifact_roots", []), int(data.get("expect_min_bytes", 0) or 0)
    )
    declared = artifact.get("declared_path", "")
    if not declared:
        verification = {"state": "not_required", "verified": True, "checked_at": now(), "reason": "no expected artifact"}
        artifact["verification"] = verification
        data["artifact"] = artifact
        data["verified"] = True
        return verification
    path = Path(artifact.get("canonical_path", ""))
    roots = [Path(value).resolve(strict=False) for value in artifact.get("allowed_roots", [])]
    current = snapshot(path)
    baseline = artifact.get("baseline", {})
    in_root = bool(roots) and contained(path.resolve(strict=False), roots)
    changed = (
        not baseline.get("exists", False)
        or current.get("size") != baseline.get("size")
        or current.get("mtime_ns") != baseline.get("mtime_ns")
        or current.get("sha256") != baseline.get("sha256")
    )
    verified = bool(
        in_root
        and current.get("exists")
        and current.get("regular_file")
        and int(current.get("size", 0)) >= int(artifact.get("min_bytes", 0) or 0)
        and changed
    )
    reasons = []
    if not in_root: reasons.append("outside_allowed_roots")
    if not current.get("exists"): reasons.append("missing")
    elif not current.get("regular_file"): reasons.append("not_regular_file")
    if int(current.get("size", 0)) < int(artifact.get("min_bytes", 0) or 0): reasons.append("undersized")
    if current.get("exists") and not changed: reasons.append("unchanged_from_dispatch")
    verification = {
        "state": "verified" if verified else "failed",
        "verified": verified,
        "checked_at": now(),
        "reason": "ok" if verified else ",".join(reasons),
        "current": current,
        "changed_since_dispatch": changed,
        "inside_allowed_roots": in_root,
        "provenance": {
            "declared_path": artifact.get("declared_path", ""),
            "canonical_path": str(path),
            "allowed_roots": [str(root) for root in roots],
            "baseline_sha256": baseline.get("sha256", ""),
            "final_sha256": current.get("sha256", ""),
        },
    }
    artifact["verification"] = verification
    data["artifact"] = artifact
    data["expected_file_exists"] = bool(current.get("exists"))
    data["expected_file_bytes"] = int(current.get("size", 0))
    data["expected_file_sha256"] = current.get("sha256", "")
    data["verified"] = verified
    if not verified:
        data["verification_error"] = verification["reason"]
    else:
        data.pop("verification_error", None)
    return verification


def command_terminal(args: argparse.Namespace) -> None:
    registry = Path(args.registry)
    result_data: dict[str, Any] = {}
    if args.result_file:
        with open(args.result_file, encoding="utf-8") as handle:
            result_data = json.load(handle)
    status_map = {"ok": "done", "error": "failed", "timeout": "timeout"}
    desired_status = args.status or status_map.get(result_data.get("status", ""), "failed" if args.exit_code else "done")
    def finish(data: dict[str, Any]):
        if data.get("status") in TERMINAL:
            return data
        desired = desired_status
        data["session_id"] = result_data.get("session_id", args.session_id) or data.get("session_id", "")
        data["cost_usd"] = float(result_data.get("cost_usd", args.cost_usd) or 0)
        data["result_preview"] = str(result_data.get("result", args.result_preview))[:200]
        for key in ("turns", "duration_ms", "result_subtype"):
            if key in result_data:
                data[key] = result_data[key]
        data["exit_code"] = result_data.get("exit_code", args.exit_code)
        verification = verify_artifact(data)
        if desired == "done" and not verification.get("verified", False):
            desired = "incomplete"
        data["status"] = desired
        requested = data.get("continuation_mode", "")
        data["terminal_decision"] = {
            "state": "pending_parent_confirmation",
            "requested": requested,
            "decision": "",
            "reason": "",
            "emitted_at": now(),
            "artifact_verified": bool(verification.get("verified", False)),
        }
        return data
    print(json.dumps(update(registry, finish), sort_keys=True))


def command_status(args: argparse.Namespace) -> None:
    print(json.dumps(load(Path(args.registry)), sort_keys=True))


def command_progress(args: argparse.Namespace) -> None:
    registry = Path(args.registry)
    stream = Path(args.stream_file)
    assistant_count = 0
    event_count = 0
    last_assistant = ""
    session_id = ""
    if stream.exists():
        with stream.open(encoding="utf-8", errors="replace") as handle:
            for raw in handle:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    event = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                event_count += 1
                if event.get("session_id"):
                    session_id = event["session_id"]
                else:
                    session_id = ""
                if event.get("type") == "assistant":
                    assistant_count += 1
                    message = event.get("message", {})
                    content = message.get("content", []) if isinstance(message, dict) else []
                    for item in content:
                        if isinstance(item, dict) and item.get("type") == "text":
                            last_assistant = str(item.get("text", ""))
    def patch(data: dict[str, Any]):
        if data.get("status") in TERMINAL:
            return data
        if session_id:
            data["session_id"] = session_id
        data["event_count"] = event_count
        data["assistant_messages"] = assistant_count
        if last_assistant and not data.get("result_preview"):
            data["result_preview"] = last_assistant[:200]
        return data
    print(json.dumps(update(registry, patch), sort_keys=True))


def command_cancel(args: argparse.Namespace) -> None:
    registry = Path(args.registry)
    def cancel(data: dict[str, Any]):
        if data.get("status") not in TERMINAL:
            data["status"] = "cancelled"
            data["terminal_decision"] = {"state": "pending_parent_confirmation", "requested": "blocked", "decision": "", "emitted_at": now()}
        return data
    print(json.dumps(update(registry, cancel), sort_keys=True))


def command_callback_claim(args: argparse.Namespace) -> None:
    registry = Path(args.registry)
    def claim(data: dict[str, Any]):
        callback = data.setdefault("callback", {"state": "pending", "attempts": 0, "lease_expires_at": "", "receipt": {}})
        if callback.get("state") == "sent":
            return {"claimed": False, "reason": "already_sent", "callback": callback}
        expiry = parse_time(callback.get("lease_expires_at"))
        current = dt.datetime.now(dt.timezone.utc).astimezone()
        if callback.get("state") == "in_progress" and expiry and expiry > current:
            return {"claimed": False, "reason": "lease_active", "callback": callback}
        if int(callback.get("attempts", 0)) >= args.max_attempts:
            return {"claimed": False, "reason": "attempts_exhausted", "callback": callback}
        callback["state"] = "in_progress"
        callback["attempts"] = int(callback.get("attempts", 0)) + 1
        callback["lease_owner"] = args.owner
        callback["lease_started_at"] = now()
        callback["lease_expires_at"] = (current + dt.timedelta(seconds=args.lease_seconds)).isoformat(timespec="seconds")
        callback.pop("last_error", None)
        return {"claimed": True, "reason": "claimed", "callback": callback}
    result = update(registry, claim)
    print(json.dumps(result, sort_keys=True))
    if not result.get("claimed"):
        raise SystemExit(3)


def load_receipt(args: argparse.Namespace) -> dict[str, Any]:
    if args.receipt_file:
        try:
            with open(args.receipt_file, encoding="utf-8") as handle:
                return json.load(handle)
        except Exception:
            return {"receipt_file": args.receipt_file, "parse_error": True}
    if args.receipt_json:
        try:
            return json.loads(args.receipt_json)
        except json.JSONDecodeError:
            return {"raw": args.receipt_json}
    return {}


def command_callback_finish(args: argparse.Namespace) -> None:
    registry = Path(args.registry)
    receipt = load_receipt(args)
    def finish(data: dict[str, Any]):
        callback = data.setdefault("callback", {})
        callback["state"] = args.state
        callback["lease_expires_at"] = ""
        callback["lease_owner"] = ""
        callback["finished_at"] = now()
        callback["receipt"] = receipt
        if args.state == "sent":
            callback["sent_at"] = now()
            callback.pop("last_error", None)
        else:
            callback["last_error"] = args.error or "callback failed"
        return callback
    print(json.dumps(update(registry, finish), sort_keys=True))


def command_legacy_reconcile(args: argparse.Namespace) -> None:
    registry = Path(args.registry)
    receipt = load_receipt(args)
    def reconcile(data: dict[str, Any]):
        data["legacy_delivery"] = {
            "state": args.state,
            "marker": args.marker,
            "reconciled_at": now(),
            "receipt": receipt,
        }
        if args.state == "sent":
            callback = data.setdefault("callback", {})
            callback.update({"state": "sent", "sent_at": now(), "lease_expires_at": "", "receipt": receipt})
        return data["legacy_delivery"]
    print(json.dumps(update(registry, reconcile), sort_keys=True))


def command_decide(args: argparse.Namespace) -> None:
    registry = Path(args.registry)
    decision = args.decision
    if decision == "continue" and not args.next_action.strip():
        raise SystemExit("continue requires --next-action")
    if decision == "switch" and (not args.next_action.strip() or not args.reason.strip()):
        raise SystemExit("switch requires --next-action and --reason")
    if decision == "blocked" and (not args.owner.strip() or not args.retry_trigger.strip() or not args.reason.strip()):
        raise SystemExit("blocked requires --owner, --retry-trigger, and --reason")
    if decision == "complete" and not args.reason.strip():
        raise SystemExit("complete requires --reason")
    def decide(data: dict[str, Any]):
        if data.get("status") not in TERMINAL:
            raise SystemExit("terminal decision requires terminal task state")
        data["terminal_decision"] = {
            "state": "confirmed",
            "decision": decision,
            "reason": args.reason,
            "next_action": args.next_action,
            "owner": args.owner,
            "retry_trigger": args.retry_trigger,
            "decided_at": now(),
        }
        return data["terminal_decision"]
    print(json.dumps(update(registry, decide), sort_keys=True))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    init = sub.add_parser("init")
    init.add_argument("--registry", required=True)
    init.add_argument("--task-id", required=True)
    init.add_argument("--session-id", default="")
    init.add_argument("--label", required=True)
    init.add_argument("--workdir", required=True)
    init.add_argument("--model", required=True)
    init.add_argument("--budget", required=True)
    init.add_argument("--timeout-secs", type=nonnegative_int, default=0)
    init.add_argument("--notify-cmd", default="")
    init.add_argument("--batch-id", default="")
    init.add_argument("--resumed-from", default="")
    init.add_argument("--expected-file", default="")
    init.add_argument("--expect-min-bytes", type=nonnegative_int, default=0)
    init.add_argument("--allowed-root", action="append", default=[])
    init.add_argument("--next-action", required=True)
    init.add_argument("--continuation-mode", choices=sorted(DECISIONS), required=True)
    init.add_argument("--owner-agent-id", default="")
    init.add_argument("--owner-session-key", default="")
    init.add_argument("--delivery-channel", default="")
    init.add_argument("--delivery-target", default="")
    init.add_argument("--delivery-account", default="")
    init.set_defaults(func=command_init)

    pid = sub.add_parser("patch-pid")
    pid.add_argument("--registry", required=True)
    pid.add_argument("--pid", type=positive_int, required=True)
    pid.set_defaults(func=command_patch_pid)

    terminal = sub.add_parser("terminal")
    terminal.add_argument("--registry", required=True)
    terminal.add_argument("--status", choices=sorted(TERMINAL))
    terminal.add_argument("--result-file", default="")
    terminal.add_argument("--exit-code", type=int, default=0)
    terminal.add_argument("--session-id", default="")
    terminal.add_argument("--cost-usd", type=float, default=0.0)
    terminal.add_argument("--result-preview", default="")
    terminal.set_defaults(func=command_terminal)

    status = sub.add_parser("status")
    status.add_argument("--registry", required=True)
    status.set_defaults(func=command_status)

    progress = sub.add_parser("progress")
    progress.add_argument("--registry", required=True)
    progress.add_argument("--stream-file", required=True)
    progress.set_defaults(func=command_progress)

    cancel = sub.add_parser("cancel")
    cancel.add_argument("--registry", required=True)
    cancel.set_defaults(func=command_cancel)

    claim = sub.add_parser("callback-claim")
    claim.add_argument("--registry", required=True)
    claim.add_argument("--lease-seconds", type=positive_int, default=900)
    claim.add_argument("--max-attempts", type=positive_int, default=3)
    claim.add_argument("--owner", required=True)
    claim.set_defaults(func=command_callback_claim)

    finish = sub.add_parser("callback-finish")
    finish.add_argument("--registry", required=True)
    finish.add_argument("--state", choices=["sent", "failed"], required=True)
    finish.add_argument("--receipt-file", default="")
    finish.add_argument("--receipt-json", default="")
    finish.add_argument("--error", default="")
    finish.set_defaults(func=command_callback_finish)

    legacy = sub.add_parser("legacy-reconcile")
    legacy.add_argument("--registry", required=True)
    legacy.add_argument("--state", choices=["sent", "quarantined"], required=True)
    legacy.add_argument("--marker", required=True)
    legacy.add_argument("--receipt-file", default="")
    legacy.add_argument("--receipt-json", default="")
    legacy.set_defaults(func=command_legacy_reconcile)

    decide = sub.add_parser("decide")
    decide.add_argument("--registry", required=True)
    decide.add_argument("--decision", choices=sorted(DECISIONS), required=True)
    decide.add_argument("--reason", default="")
    decide.add_argument("--next-action", default="")
    decide.add_argument("--owner", default="")
    decide.add_argument("--retry-trigger", default="")
    decide.set_defaults(func=command_decide)
    return parser


def main() -> None:
    args = build_parser().parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
