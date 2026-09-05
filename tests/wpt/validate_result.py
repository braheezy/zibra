#!/usr/bin/env python3
"""Validate one Zibra WPT JSONL result produced by an integration fixture."""

from __future__ import annotations

import argparse
import pathlib

from protocol import parse_json_record
from diagnostics import analyze_testharness


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result", type=pathlib.Path)
    parser.add_argument(
        "--status", required=True, choices=("PASS", "FAIL", "ERROR", "TIMEOUT")
    )
    parser.add_argument("--test-suffix", required=True)
    parser.add_argument("--stderr", type=pathlib.Path)
    parser.add_argument("--diagnostic-reason")
    parser.add_argument("--error-kind")
    parser.add_argument("--partial-subtests", type=int)
    args = parser.parse_args()

    record = parse_json_record(args.result.read_text(encoding="utf-8"))

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
    if args.stderr is not None:
        diagnostics = analyze_testharness(
            args.test_suffix, record["test"], args.stderr.read_text(encoding="utf-8"), record,
        )
        if args.diagnostic_reason is not None and diagnostics["reason"] != args.diagnostic_reason:
            raise ValueError(f"expected diagnosis {args.diagnostic_reason}, got {diagnostics}")
        if args.error_kind is not None and not any(
            error.get("error_kind") == args.error_kind for error in diagnostics["script_errors"]
        ):
            raise ValueError(f"missing script error {args.error_kind}: {diagnostics}")
        if args.partial_subtests is not None and diagnostics["completed_subtests_observed"] != args.partial_subtests:
            raise ValueError(f"expected {args.partial_subtests} observed subtests, got {diagnostics}")
        if args.status == "PASS" and diagnostics["script_errors"]:
            raise ValueError(f"caught exceptions should not become uncaught diagnostics: {diagnostics}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
