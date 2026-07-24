#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
ADAPTER = Path("/data/landscapio-ceo/scripts/zara-claude-delegate.sh")


class ZaraAdapterContractTests(unittest.TestCase):
    """Exercise Zara's adapter through the real shared CLI parser.

    The downstream profile/orchestrator executors are replaced with no-network
    capture stubs. This catches argument-order and positional-boundary bugs that
    a permissive stand-alone argv stub cannot detect.
    """

    def setUp(self):
        if not ADAPTER.exists():
            self.skipTest(f"Zara adapter is not installed: {ADAPTER}")
        self.temp = Path(tempfile.mkdtemp(prefix="zara-adapter-contract-", dir="/data/tmp"))
        self.delegate_root = self.temp / "delegate-root"
        self.delegate_root.mkdir()
        self.calls = self.temp / "calls.jsonl"
        self.notify = Path("/data/landscapio-ceo/scripts/notify-zara-background-task.sh")
        if not self.notify.exists():
            self.skipTest(f"Zara callback is not installed: {self.notify}")

        capture = self.delegate_root / "capture.py"
        capture.write_text(
            """#!/usr/bin/env python3
import json, os, sys
with open(os.environ['ZARA_ADAPTER_CALLS'], 'a', encoding='utf-8') as fh:
    fh.write(json.dumps({'entrypoint': os.environ['ZARA_ADAPTER_ENTRYPOINT'], 'argv': sys.argv[1:]}) + '\\n')
""",
            encoding="utf-8",
        )
        capture.chmod(0o755)
        for name, entrypoint in (("cc-profile.sh", "profile"), ("cc-orchestrator.sh", "orchestrator")):
            script = self.delegate_root / name
            script.write_text(
                f"#!/usr/bin/env bash\nset -euo pipefail\n"
                f"export ZARA_ADAPTER_ENTRYPOINT={entrypoint!r}\n"
                f"exec python3 {str(capture)!r} \"$@\"\n",
                encoding="utf-8",
            )
            script.chmod(0o755)

    def tearDown(self):
        if hasattr(self, "temp"):
            shutil.rmtree(self.temp)

    def run_adapter(self, *args: str) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "CLAUDE_DELEGATE_ROOT": str(self.delegate_root),
                "CLAUDE_OAUTH_ENV_FILE": "/dev/null",
                "ZARA_ADAPTER_CALLS": str(self.calls),
            }
        )
        return subprocess.run(
            [str(ADAPTER), *args],
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )

    def load_single_call(self) -> dict:
        rows = [json.loads(line) for line in self.calls.read_text(encoding="utf-8").splitlines() if line]
        self.assertEqual(len(rows), 1, rows)
        return rows[0]

    @staticmethod
    def controls() -> list[str]:
        return [
            "--timeout", "30",
            "--expect-file", "/data/landscapio-ceo/reports/contract/result.md",
            "--expect-min-bytes", "1",
            "--next-action", "continue controlled contract test",
            "--continuation-mode", "continue",
        ]

    def test_dispatch_matches_real_shared_cli_contract(self):
        task = "Write the artifact; preserve literal --option-shaped task text."
        result = self.run_adapter("dispatch", "none", "default", "contract-dispatch", task, *self.controls())
        self.assertEqual(result.returncode, 0, result.stderr)
        call = self.load_single_call()
        self.assertEqual(call["entrypoint"], "profile")
        self.assertEqual(
            call["argv"][:6],
            ["zara", "dispatch", "none", "default", "contract-dispatch", task],
        )
        self.assertNotIn("/data/landscapio-ceo", call["argv"][:6])
        self.assertEqual(call["argv"][6:8], ["--timeout", "30"])

    def test_resume_matches_real_shared_cli_contract_without_profile(self):
        follow_up = "Continue the same task; preserve literal --option-shaped follow-up text."
        result = self.run_adapter("resume", "task-123", "none", follow_up, *self.controls())
        self.assertEqual(result.returncode, 0, result.stderr)
        call = self.load_single_call()
        self.assertEqual(call["entrypoint"], "orchestrator")
        self.assertEqual(
            call["argv"][:4],
            ["resume", "task-123", "none", follow_up],
        )
        self.assertNotIn("zara", call["argv"][:4])
        self.assertEqual(call["argv"][4:6], ["--timeout", "30"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
