#!/usr/bin/env python3
"""Run Zibra's reviewed WPT probes and testharness cases.

``probe`` remains a fetch/parse smoke test and is never a WPT conformance
result. ``testharness`` consumes Zibra's machine-readable headless result.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys
from dataclasses import dataclass
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST = pathlib.Path(__file__).with_name("manifest.json")
UPSTREAM = pathlib.Path(__file__).with_name("upstream")
DEFAULT_TIMEOUT_MS = 10_000
WATCHDOG_GRACE_SECONDS = 5.0
RESULT_STATUSES = frozenset(("PASS", "FAIL", "ERROR", "TIMEOUT"))
EXPECTATIONS = {
    "pass": "PASS",
    "fail": "FAIL",
    "error": "ERROR",
    "timeout": "TIMEOUT",
}


@dataclass(frozen=True)
class Case:
    path: str
    mode: str
    reason: str
    status: str = "candidate"
    timeout_ms: int = DEFAULT_TIMEOUT_MS
    expectation: str | None = None

    @property
    def skipped(self) -> bool:
        return self.status.lower() == "skip" or (
            self.expectation is not None and self.expectation.lower() == "skip"
        )

    @property
    def expected_status(self) -> str:
        if self.expectation is None:
            return "PASS"
        return EXPECTATIONS[self.expectation.lower()]


@dataclass(frozen=True)
class ProcessOutcome:
    stdout: str
    stderr: str
    infrastructure_error: str | None = None


def _as_text(value: str | bytes | None) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return value


def _validate_case(case: Case, index: int) -> None:
    prefix = f"tests[{index}]"
    if not isinstance(case.path, str) or not case.path:
        raise ValueError(f"{prefix}.path must be a non-empty string")
    if case.mode not in ("probe", "testharness"):
        raise ValueError(f"{prefix}.mode must be probe or testharness")
    if not isinstance(case.status, str):
        raise ValueError(f"{prefix}.status must be a string")
    if not isinstance(case.reason, str) or not case.reason:
        raise ValueError(f"{prefix}.reason must be a non-empty string")
    if type(case.timeout_ms) is not int or case.timeout_ms <= 0:
        raise ValueError(f"{prefix}.timeout_ms must be a positive integer")
    if case.expectation is not None:
        if not isinstance(case.expectation, str):
            raise ValueError(f"{prefix}.expectation must be a string")
        expectation = case.expectation.lower()
        if expectation != "skip" and expectation not in EXPECTATIONS:
            choices = ", ".join((*EXPECTATIONS, "skip"))
            raise ValueError(f"{prefix}.expectation must be one of: {choices}")


def load_cases(path: pathlib.Path) -> list[Case]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or data.get("version") != 1:
        raise ValueError("unsupported WPT manifest version")
    items = data.get("tests", [])
    if not isinstance(items, list):
        raise ValueError("manifest tests must be an array")

    cases = []
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            raise ValueError(f"tests[{index}] must be an object")
        try:
            case = Case(**item)
        except TypeError as error:
            raise ValueError(f"invalid tests[{index}] entry: {error}") from error
        _validate_case(case, index)
        cases.append(case)
    return cases


def _invoke(command: list[str], watchdog_seconds: float) -> ProcessOutcome:
    try:
        result = subprocess.run(
            command,
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=watchdog_seconds,
        )
    except subprocess.TimeoutExpired as error:
        return ProcessOutcome(
            stdout=_as_text(error.stdout),
            stderr=_as_text(error.stderr),
            infrastructure_error=(
                f"browser watchdog expired after {watchdog_seconds:.3f} seconds"
            ),
        )
    except OSError as error:
        return ProcessOutcome(
            stdout="",
            stderr="",
            infrastructure_error=f"failed to start browser: {error}",
        )

    if result.returncode != 0:
        return ProcessOutcome(
            stdout=result.stdout,
            stderr=result.stderr,
            infrastructure_error=f"browser exited with status {result.returncode}",
        )
    return ProcessOutcome(stdout=result.stdout, stderr=result.stderr)


def parse_testharness_result(stdout: str, expected_url: str) -> dict[str, Any]:
    lines = stdout.splitlines()
    if len(lines) != 1 or not lines[0].strip():
        raise ValueError(
            f"expected exactly one JSON result line, received {len(lines)}"
        )
    try:
        record = json.loads(lines[0])
    except json.JSONDecodeError as error:
        raise ValueError(f"invalid JSON result: {error.msg}") from error
    if not isinstance(record, dict):
        raise ValueError("JSON result must be an object")

    protocol_version = record.get("protocol_version")
    if type(protocol_version) is not int or protocol_version != 1:
        raise ValueError("JSON result protocol_version must be integer 1")
    if record.get("test") != expected_url:
        raise ValueError("JSON result test URL does not match the requested URL")
    status = record.get("status")
    if status not in RESULT_STATUSES:
        raise ValueError(
            "JSON result status must be PASS, FAIL, ERROR, or TIMEOUT"
        )
    duration_ms = record.get("duration_ms")
    if type(duration_ms) is not int or duration_ms < 0:
        raise ValueError("JSON result duration_ms must be a non-negative integer")
    return record


def _write_raw_diagnostics(outcome: ProcessOutcome) -> None:
    for label, value in (
        ("browser stdout", outcome.stdout),
        ("browser stderr", outcome.stderr),
    ):
        print(f"--- {label} ---", file=sys.stderr)
        if value:
            sys.stderr.write(value)
            if not value.endswith("\n"):
                sys.stderr.write("\n")
        else:
            print("<empty>", file=sys.stderr)


def _run_probe(case: Case, url: str, browser: list[str]) -> bool:
    watchdog_seconds = case.timeout_ms / 1000 + WATCHDOG_GRACE_SECONDS
    outcome = _invoke([*browser, "--dump-dom", url], watchdog_seconds)
    if outcome.infrastructure_error is not None:
        print(f"INFRA {case.path}: {outcome.infrastructure_error}")
        _write_raw_diagnostics(outcome)
        return False
    print(f"probe ok (non-conformance) {case.path}")
    return True


def _run_testharness(case: Case, url: str, browser: list[str]) -> bool:
    watchdog_seconds = case.timeout_ms / 1000 + WATCHDOG_GRACE_SECONDS
    outcome = _invoke(
        [
            *browser,
            "--wpt-test",
            url,
            "--wpt-timeout-ms",
            str(case.timeout_ms),
        ],
        watchdog_seconds,
    )
    if outcome.infrastructure_error is not None:
        print(f"INFRA {case.path}: {outcome.infrastructure_error}")
        _write_raw_diagnostics(outcome)
        return False

    try:
        record = parse_testharness_result(outcome.stdout, url)
    except ValueError as error:
        print(f"INFRA {case.path}: {error}")
        _write_raw_diagnostics(outcome)
        return False

    actual = record["status"]
    expected = case.expected_status
    if actual != expected:
        print(f"FAIL {case.path}: expected {expected}, received {actual}")
        _write_raw_diagnostics(outcome)
        return False
    print(f"ok {case.path}: {actual}")
    return True


def _parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "manifest", nargs="?", type=pathlib.Path, default=DEFAULT_MANIFEST
    )
    parser.add_argument("--list", action="store_true", help="list manifest entries")
    parser.add_argument(
        "--mode", choices=("probe", "testharness"), default="probe"
    )
    parser.add_argument(
        "--browser",
        nargs="+",
        default=["zig", "build", "run", "--"],
        help="command prefix used to invoke Zibra (default: zig build run --)",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    try:
        cases = load_cases(args.manifest)
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"Failed to load WPT manifest: {error}", file=sys.stderr)
        return 2

    if args.list:
        for case in cases:
            claim = "skip" if case.skipped else case.expectation or case.status
            print(f"{claim:9} {case.mode:11} {case.path}  # {case.reason}")
        return 0

    if not UPSTREAM.is_dir():
        print(
            "WPT checkout missing; run the git submodule commands in tests/wpt/README.md.",
            file=sys.stderr,
        )
        return 2

    failed = 0
    for case in cases:
        if case.skipped or case.mode != args.mode:
            continue
        test_path = (UPSTREAM / case.path).resolve()
        if not test_path.is_file():
            if case.mode == "probe":
                print(f"SKIP {case.path} (missing from checkout)")
            else:
                print(f"INFRA {case.path}: missing from checkout")
                failed += 1
            continue

        url = test_path.as_uri()
        if case.mode == "probe":
            ok = _run_probe(case, url, args.browser)
        else:
            ok = _run_testharness(case, url, args.browser)
        if not ok:
            failed += 1
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
