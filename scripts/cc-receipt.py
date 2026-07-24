#!/usr/bin/env python3
"""Validate OpenClaw callback receipts across CLI response envelopes."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def delivered(data: Any) -> bool:
    if not isinstance(data, dict):
        return False

    # `openclaw agent --deliver --json` receipts.
    delivery = data.get("deliveryStatus")
    if isinstance(delivery, dict):
        if delivery.get("succeeded") is True or delivery.get("status") == "sent":
            return True

    # `openclaw message send --json` currently puts `ok` under payload while
    # retaining messageId at both the top level and under payload. Accept the
    # older flat envelope too so callback verification survives either shape.
    payload = data.get("payload")
    payload = payload if isinstance(payload, dict) else {}
    ok = data.get("ok") is True or payload.get("ok") is True
    message_id = (
        data.get("messageId")
        or data.get("message_id")
        or payload.get("messageId")
        or payload.get("message_id")
    )
    return ok and bool(message_id)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("receipt", type=Path)
    args = parser.parse_args()
    try:
        data = json.loads(args.receipt.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return 1
    return 0 if delivered(data) else 1


if __name__ == "__main__":
    raise SystemExit(main())
