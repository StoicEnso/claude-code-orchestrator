#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "cc-receipt.py"
SPEC = importlib.util.spec_from_file_location("cc_receipt", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(MODULE)


class CallbackReceiptTests(unittest.TestCase):
    def test_flat_message_receipt(self):
        self.assertTrue(MODULE.delivered({"ok": True, "messageId": "1"}))

    def test_nested_payload_message_receipt(self):
        self.assertTrue(
            MODULE.delivered(
                {"action": "send", "messageId": "2", "payload": {"ok": True, "messageId": "2"}}
            )
        )

    def test_agent_delivery_receipt(self):
        self.assertTrue(MODULE.delivered({"deliveryStatus": {"status": "sent"}}))

    def test_unconfirmed_or_malformed_receipts_fail_closed(self):
        self.assertFalse(MODULE.delivered({"payload": {"ok": True}}))
        self.assertFalse(MODULE.delivered({"messageId": "3"}))
        self.assertFalse(MODULE.delivered([]))

    def test_cli_exit_status(self):
        with tempfile.TemporaryDirectory() as temp:
            good = Path(temp) / "good.json"
            bad = Path(temp) / "bad.json"
            good.write_text(json.dumps({"payload": {"ok": True, "messageId": "4"}}))
            bad.write_text("not-json")
            self.assertEqual(subprocess.run([str(SCRIPT), str(good)]).returncode, 0)
            self.assertEqual(subprocess.run([str(SCRIPT), str(bad)]).returncode, 1)

    def test_zara_notify_accepts_nested_direct_receipt(self):
        notify = Path("/data/landscapio-ceo/scripts/notify-zara-background-task.sh")
        if not notify.exists():
            self.skipTest("Zara notify adapter is not installed")
        with tempfile.TemporaryDirectory() as temp:
            temp_path = Path(temp)
            task_id = f"receipt-contract-{os.getpid()}"
            registry = temp_path / "registry.json"
            registry.write_text(json.dumps({"callback": {"state": "in_progress"}}))
            fake = temp_path / "openclaw"
            fake.write_text(
                "#!/usr/bin/env bash\n"
                "if [ \"$1\" = agent ]; then exit 1; fi\n"
                "printf '%s\\n' '{\"action\":\"send\",\"messageId\":\"99\",\"payload\":{\"ok\":true,\"messageId\":\"99\"}}'\n"
            )
            fake.chmod(0o755)
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{temp}:{env['PATH']}",
                    "CC_NOTIFY_TASK_ID": task_id,
                    "CC_NOTIFY_REGISTRY_FILE": str(registry),
                    "CC_NOTIFY_STATUS": "done",
                    "CC_RECEIPT_CHECKER": str(SCRIPT),
                }
            )
            result = subprocess.run([str(notify)], text=True, capture_output=True, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(json.loads(result.stdout)["payload"]["ok"])
            for suffix in (".zara-agent.json", ".zara-agent.err", ".zara-fallback.json"):
                Path(f"/tmp/claude-subagent-hooks/{task_id}{suffix}").unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
