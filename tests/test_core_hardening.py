#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[3]
STATE = ROOT / "skills/claude-delegate/scripts/cc-state.py"
SWEEPER = ROOT / "tools/cc-task-sweeper.sh"
MIGRATE = ROOT / "skills/claude-delegate/scripts/reconcile-legacy-markers.py"


class CoreHardeningTests(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="cc-hardening-", dir="/data/tmp"))
        self.registry_dir = self.temp / "registry"
        self.hooks_dir = self.temp / "hooks"
        self.workdir = self.temp / "work"
        self.registry_dir.mkdir(); self.hooks_dir.mkdir(); self.workdir.mkdir()

    def tearDown(self):
        shutil.rmtree(self.temp)

    def run_state(self, *args, check=True):
        return subprocess.run(["python3", str(STATE), *map(str,args)], text=True, capture_output=True, check=check)

    def init(self, task="task", expected="", min_bytes=0, routed=False):
        registry = self.registry_dir / f"{task}.json"
        command = [
            "init", "--registry", registry, "--task-id", task, "--label", task,
            "--workdir", self.workdir, "--model", "test", "--budget", "1",
            "--expected-file", expected, "--expect-min-bytes", str(min_bytes),
            "--next-action", "continue test", "--continuation-mode", "continue",
        ]
        if routed:
            command += [
                "--owner-agent-id", "landscapio-ceo", "--owner-session-key", "agent:landscapio-ceo:test",
                "--delivery-channel", "telegram", "--delivery-target", "5173761146",
                "--delivery-account", "landscapio-ceo",
            ]
        self.run_state(*command)
        return registry

    def load(self, path):
        return json.loads(Path(path).read_text())

    def test_relative_path_normalized_independent_of_cwd(self):
        (self.workdir / "sub").mkdir()
        registry = self.init(expected="sub/artifact.txt", min_bytes=2)
        data = self.load(registry)
        self.assertEqual(data["expected_file_canonical"], str((self.workdir / "sub/artifact.txt").resolve()))
        artifact = self.workdir / "sub/artifact.txt"
        artifact.write_text("fresh")
        subprocess.run(["python3", str(STATE), "terminal", "--registry", str(registry), "--status", "done"], cwd="/tmp", check=True)
        data = self.load(registry)
        self.assertEqual(data["status"], "done")
        self.assertTrue(data["verified"])

    def test_traversal_and_symlink_escape_rejected(self):
        outside = self.temp / "outside"; outside.mkdir()
        bad = self.run_state(
            "init", "--registry", self.registry_dir / "bad.json", "--task-id", "bad", "--label", "bad",
            "--workdir", self.workdir, "--model", "test", "--budget", "1",
            "--expected-file", "../outside/file", "--next-action", "x", "--continuation-mode", "continue", check=False,
        )
        self.assertNotEqual(bad.returncode, 0)
        (self.workdir / "link").symlink_to(outside, target_is_directory=True)
        bad2 = self.run_state(
            "init", "--registry", self.registry_dir / "bad2.json", "--task-id", "bad2", "--label", "bad2",
            "--workdir", self.workdir, "--model", "test", "--budget", "1",
            "--expected-file", "link/file", "--next-action", "x", "--continuation-mode", "continue", check=False,
        )
        self.assertNotEqual(bad2.returncode, 0)

    def test_preexisting_unchanged_is_incomplete_but_changed_hash_passes(self):
        artifact = self.workdir / "artifact.txt"; artifact.write_text("baseline")
        registry = self.init(task="unchanged", expected="artifact.txt", min_bytes=3)
        self.run_state("terminal", "--registry", registry, "--status", "done")
        data = self.load(registry)
        self.assertEqual(data["status"], "incomplete")
        self.assertIn("unchanged_from_dispatch", data["verification_error"])

        artifact.write_text("baseline-two")
        registry2 = self.init(task="changed", expected="artifact.txt", min_bytes=3)
        artifact.write_text("fresh-content")
        self.run_state("terminal", "--registry", registry2, "--status", "done")
        data2 = self.load(registry2)
        self.assertEqual(data2["status"], "done")
        self.assertTrue(data2["artifact"]["verification"]["changed_since_dispatch"])
        self.assertEqual(len(data2["expected_file_sha256"]), 64)

    def test_fast_terminal_pid_patch_cannot_overwrite_terminal(self):
        registry = self.init(task="fast")
        self.run_state("terminal", "--registry", registry, "--status", "done")
        result = json.loads(self.run_state("patch-pid", "--registry", registry, "--pid", "12345").stdout)
        self.assertFalse(result["patched"])
        data = self.load(registry)
        self.assertEqual(data["status"], "done")
        self.assertEqual(data["pid"], "")

    def test_orchestrator_fast_dispatch_integration(self):
        scripts = self.temp / "scripts"; scripts.mkdir()
        shutil.copy2(ROOT / "skills/claude-delegate/scripts/cc-orchestrator.sh", scripts / "cc-orchestrator.sh")
        shutil.copy2(STATE, scripts / "cc-state.py")
        run_task = scripts / "run-task.sh"
        run_task.write_text("""#!/usr/bin/env bash
set -e
if [ "$1" = run ]; then
  mkdir -p "$2/sub"; printf 'new artifact\\n' > "$2/sub/result.txt"
  echo '{"status":"ok","session_id":"stub-session","cost_usd":0,"result":"done","turns":1}'
else
  exit 2
fi
""")
        for path in scripts.iterdir(): path.chmod(0o755)
        env = {
            **os.environ, "CC_REGISTRY_DIR": str(self.registry_dir), "CC_RESULTS_DIR": str(self.temp/"results"),
            "CC_LOGS_DIR": str(self.temp/"logs"), "CC_HOOKS_DIR": str(self.hooks_dir), "CC_COST_LOG": str(self.temp/"costs.jsonl"),
        }
        result = subprocess.run([
            "bash", str(scripts/"cc-orchestrator.sh"), "dispatch", str(self.workdir), "1", "test", "fast-integration", "stub",
            "--expect-file", "sub/result.txt", "--expect-min-bytes", "3", "--next-action", "finish", "--continuation-mode", "complete",
        ], cwd="/tmp", env=env, text=True, capture_output=True, check=True)
        task_id = json.loads(result.stdout)["task_id"]
        registry = self.registry_dir / f"{task_id}.json"
        for _ in range(50):
            data = self.load(registry)
            if data["status"] != "running": break
            time.sleep(0.05)
        self.assertEqual(data["status"], "done")
        self.assertTrue(data["verified"])
        self.assertEqual(data["expected_file_canonical"], str((self.workdir/"sub/result.txt").resolve()))
        self.assertEqual(data["terminal_decision"]["state"], "pending_parent_confirmation")

    def test_orchestrator_callback_receipt_integration(self):
        scripts = self.temp / "callback-scripts"; scripts.mkdir()
        shutil.copy2(ROOT / "skills/claude-delegate/scripts/cc-orchestrator.sh", scripts / "cc-orchestrator.sh")
        shutil.copy2(STATE, scripts / "cc-state.py")
        (scripts / "run-task.sh").write_text("""#!/usr/bin/env bash
echo '{"status":"ok","session_id":"stub-session","result":"done"}'
""")
        notify = self.temp / "notify.sh"
        notify.write_text("""#!/usr/bin/env bash
python3 - "$CC_NOTIFY_REGISTRY_FILE" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))['callback']['state']=='in_progress'
print('{"deliveryStatus":{"status":"sent","succeeded":true}}')
PY
""")
        for path in list(scripts.iterdir()) + [notify]: path.chmod(0o755)
        env = {
            **os.environ, "CC_REGISTRY_DIR": str(self.registry_dir), "CC_RESULTS_DIR": str(self.temp/"results"),
            "CC_LOGS_DIR": str(self.temp/"logs"), "CC_HOOKS_DIR": str(self.hooks_dir), "CC_COST_LOG": str(self.temp/"costs.jsonl"),
        }
        result = subprocess.run([
            "bash", str(scripts/"cc-orchestrator.sh"), "dispatch", str(self.workdir), "1", "test", "callback", "stub",
            "--notify-cmd", str(notify), "--next-action", "finish", "--continuation-mode", "complete",
            "--owner-agent-id", "landscapio-ceo", "--owner-session-key", "agent:landscapio-ceo:test",
            "--delivery-channel", "telegram", "--delivery-target", "5173761146", "--delivery-account", "landscapio-ceo",
        ], env=env, text=True, capture_output=True, check=True)
        task_id = json.loads(result.stdout)["task_id"]
        registry = self.registry_dir / f"{task_id}.json"
        for _ in range(50):
            data = self.load(registry)
            if data.get("callback",{}).get("state") == "sent" and (self.hooks_dir/f"{task_id}.callback-sent").exists(): break
            time.sleep(0.05)
        self.assertEqual(data["status"], "done")
        self.assertEqual(data["callback"]["state"], "sent")
        self.assertEqual(data["callback"]["attempts"], 1)
        self.assertTrue((self.hooks_dir/f"{task_id}.callback-sent").exists())

    def test_callback_lease_retry_and_sent_dedupe(self):
        registry = self.init(task="lease")
        first = json.loads(self.run_state("callback-claim", "--registry", registry, "--lease-seconds", "1", "--owner", "one").stdout)
        self.assertTrue(first["claimed"])
        second = self.run_state("callback-claim", "--registry", registry, "--lease-seconds", "1", "--owner", "two", check=False)
        self.assertEqual(second.returncode, 3)
        self.assertEqual(json.loads(second.stdout)["reason"], "lease_active")
        time.sleep(1.2)
        third = json.loads(self.run_state("callback-claim", "--registry", registry, "--lease-seconds", "1", "--owner", "three").stdout)
        self.assertTrue(third["claimed"])
        self.run_state("callback-finish", "--registry", registry, "--state", "sent", "--receipt-json", '{"ok":true}')
        fourth = self.run_state("callback-claim", "--registry", registry, "--owner", "four", check=False)
        self.assertEqual(json.loads(fourth.stdout)["reason"], "already_sent")

    def test_structured_terminal_decision_validation(self):
        registry = self.init(task="decision")
        self.run_state("terminal", "--registry", registry, "--status", "done")
        bad = self.run_state("decide", "--registry", registry, "--decision", "blocked", "--reason", "gate", check=False)
        self.assertNotEqual(bad.returncode, 0)
        self.run_state("decide", "--registry", registry, "--decision", "blocked", "--reason", "OTP", "--owner", "Ihusan", "--retry-trigger", "OTP supplied")
        decision = self.load(registry)["terminal_decision"]
        self.assertEqual(decision["state"], "confirmed")
        self.assertEqual(decision["decision"], "blocked")

    def make_stub(self):
        stub = self.temp / "openclaw"
        stub.write_text("""#!/usr/bin/env bash
printf '%q ' "$@" >> "$CC_STUB_CALLS"; printf '\\n' >> "$CC_STUB_CALLS"
if [ "${1:-}" = agent ]; then
  echo '{"deliveryStatus":{"status":"sent","succeeded":true}}'
else
  echo '{"ok":true,"messageId":"stub-message"}'
fi
""")
        stub.chmod(0o755)
        return stub

    def sweeper_env(self, stub):
        return {
            **os.environ, "CC_REGISTRY_DIR": str(self.registry_dir), "CC_HOOKS_DIR": str(self.hooks_dir),
            "CC_SWEEPER_LOG": str(self.temp / "sweeper.log"), "CC_SWEEPER_LOCK": str(self.temp / "sweeper.lock"),
            "CC_SWEEP_GRACE_SECS": "0", "CC_STATE_TOOL": str(STATE), "CC_OPENCLAW_BIN": str(stub),
            "CC_STUB_CALLS": str(self.temp / "calls.log"),
        }

    def test_sweeper_explicit_routing_and_sent_receipt_dedupe(self):
        stub = self.make_stub(); registry = self.init(task="route", routed=True)
        self.run_state("terminal", "--registry", registry, "--status", "done")
        os.utime(registry, (time.time()-5, time.time()-5))
        subprocess.run(["bash", str(SWEEPER)], env=self.sweeper_env(stub), check=True)
        calls = (self.temp / "calls.log").read_text()
        self.assertIn("--reply-account landscapio-ceo", calls)
        self.assertIn("--session-key agent:landscapio-ceo:test", calls)
        self.assertEqual(self.load(registry)["callback"]["state"], "sent")
        self.assertTrue((self.registry_dir / "route.announced").exists())
        before = calls
        subprocess.run(["bash", str(SWEEPER)], env=self.sweeper_env(stub), check=True)
        self.assertEqual((self.temp / "calls.log").read_text(), before)

    def test_legacy_marker_reconciliation_is_conservative(self):
        registry = self.init(task="legacy", routed=True)
        self.run_state("terminal", "--registry", registry, "--status", "done")
        (self.registry_dir / "legacy.announced").touch()
        subprocess.run(["python3", str(MIGRATE), "--registry-dir", str(self.registry_dir), "--hooks-dir", str(self.hooks_dir), "--apply"], check=True)
        data = self.load(registry)
        self.assertEqual(data["legacy_delivery"]["state"], "quarantined")
        self.assertNotEqual(data["callback"]["state"], "sent")

        registry2 = self.init(task="legacy-sent", routed=True)
        self.run_state("terminal", "--registry", registry2, "--status", "done")
        (self.hooks_dir / "legacy-sent.zara-notified.ok").touch()
        (self.hooks_dir / "legacy-sent.zara-agent.json").write_text('{"deliveryStatus":{"status":"sent","succeeded":true}}')
        subprocess.run(["python3", str(MIGRATE), "--registry-dir", str(self.registry_dir), "--hooks-dir", str(self.hooks_dir), "--apply"], check=True)
        data2 = self.load(registry2)
        self.assertEqual(data2["callback"]["state"], "sent")
        self.assertTrue((self.hooks_dir / "legacy-sent.callback-sent").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
