#!/usr/bin/env python3
"""Validate one Zibra WPT JSONL result produced by an integration fixture."""

from __future__ import annotations

import argparse
import json
import pathlib


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result", type=pathlib.Path)
    parser.add_argument(
        "--status", required=True, choices=("PASS", "FAIL", "ERROR", "TIMEOUT")
    )
    parser.add_argument("--test-suffix", required=True)
    args = parser.parse_args()

    lines = args.result.read_text(encoding="utf-8").splitlines()
    if len(lines) != 1 or not lines[0].strip():
        raise ValueError(f"expected exactly one JSONL record, found {len(lines)}")
    record = json.loads(lines[0])
    if not isinstance(record, dict):
        raise ValueError("WPT result must be a JSON object")

    protocol_version = record.get("protocol_version")
    if type(protocol_version) is not int or protocol_version != 1:
        raise ValueError("unsupported or missing WPT result protocol version")
    if record.get("status") != args.status:
        raise ValueError(f"expected {args.status}, got {record.get('status')!r}")
    if not str(record.get("test", "")).endswith(args.test_suffix):
        raise ValueError(f"unexpected test URL: {record.get('test')!r}")
    duration_ms = record.get("duration_ms")
    if type(duration_ms) is not int or duration_ms < 0:
        raise ValueError("duration_ms must be a non-negative integer")
    if not isinstance(record.get("tests"), list):
        raise ValueError("tests must be an array")
    if not isinstance(record.get("console"), list):
        raise ValueError("console must be an array")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
