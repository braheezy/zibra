#!/usr/bin/env python3
"""Run Zibra's reviewed WPT probes and testharness cases.

``probe`` remains a fetch/parse smoke test and is never a WPT conformance
result. ``testharness`` consumes Zibra's machine-readable headless result.
"""

from __future__ import annotations

import argparse
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from collections import Counter
from datetime import datetime, timezone
from dataclasses import dataclass, replace
import math
import json
import os
import pathlib
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST = pathlib.Path(__file__).with_name("manifest.yaml")
UPSTREAM = pathlib.Path(__file__).with_name("upstream")
DEFAULT_TIMEOUT_MS = 10_000
WATCHDOG_GRACE_SECONDS = 5.0
WPT_SERVER_STARTUP_TIMEOUT_SECONDS = 15.0
RESULT_STATUSES = frozenset(("PASS", "FAIL", "ERROR", "TIMEOUT"))
EXPECTATIONS = {
    "pass": "PASS",
    "fail": "FAIL",
    "error": "ERROR",
    "timeout": "TIMEOUT",
}
REPORT_SCHEMA_VERSION = 1
MAX_DIAGNOSTIC_BYTES = 64 * 1024
MAX_CONSOLE_DIAGNOSTIC_BYTES = 8 * 1024
DISCOVERY_EXTENSIONS = frozenset((".html", ".htm", ".xhtml", ".xht", ".xml"))
DISCOVERY_SKIP_PREFIXES = ("resources/", "tools/", "_venv3/")


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


@dataclass(frozen=True)
class CaseResult:
    case: Case
    status: str
    ok: bool
    record: dict[str, Any] | None = None
    infrastructure_error: str | None = None
    stdout: str = ""
    stderr: str = ""


def _folder_for_path(path: str) -> str:
    """Return the top-level WPT directory used for progress accounting."""
    component = path.split("/", 1)[0]
    return f"{component}/" if "/" in path else "(root)"


class ProgressReporter:
    """Keep normal runner output compact while retaining folder milestones.

    Browser diagnostics belong in the JSON report (or behind ``--verbose``),
    not interleaved with progress from worker processes. TTYs get one live
    line; redirected output receives at most about one hundred checkpoints,
    plus one durable completion line per top-level WPT folder.
    """

    _SUMMARY_ORDER = ("PASS", "FAIL", "ERROR", "TIMEOUT", "INFRA", "PROBE", "SKIP")

    def __init__(self, cases: list[Case], mode: str, jobs: int, stream: Any = None) -> None:
        self.stream = stream if stream is not None else sys.stdout
        self.mode = mode
        self.jobs = jobs
        self.total = len(cases)
        self.folder_totals = Counter(_folder_for_path(case.path) for case in cases)
        self.folder_done = Counter()
        self.folder_status: dict[str, Counter[str]] = {}
        self.done = 0
        self._line_width = 0
        self._line_active = False
        self._tty = bool(getattr(self.stream, "isatty", lambda: False)())
        self._checkpoint_every = max(1, math.ceil(self.total / 100)) if self.total else 1

    def start(self) -> None:
        print(
            f"WPT {self.mode}: {self.total} cases ({self.jobs} workers)",
            file=self.stream,
        )

    @staticmethod
    def _label(result: CaseResult) -> str:
        if result.infrastructure_error is not None:
            return "INFRA"
        if not result.ok and result.status not in ("SKIP", "PROBE"):
            return f"{result.status} (expected {result.case.expected_status})"
        return result.status

    def record(self, result: CaseResult) -> None:
        folder = _folder_for_path(result.case.path)
        self.done += 1
        self.folder_done[folder] += 1
        self.folder_status.setdefault(folder, Counter())[result.status] += 1
        label = self._label(result)

        if self._tty:
            line = (
                f"[{self.done}/{self.total}] {folder} "
                f"{self.folder_done[folder]}/{self.folder_totals[folder]} "
                f"{label} {result.case.path}"
            )
            padding = " " * max(0, self._line_width - len(line))
            print(f"\r{line}{padding}", end="", flush=True, file=self.stream)
            self._line_width = len(line)
            self._line_active = True
        elif self.done % self._checkpoint_every == 0 or self.done == self.total:
            print(
                f"[{self.done}/{self.total}] {folder} "
                f"{self.folder_done[folder]}/{self.folder_totals[folder]} "
                f"{label} {result.case.path}",
                file=self.stream,
            )

        if self.folder_done[folder] == self.folder_totals[folder]:
            if self._line_active:
                print(file=self.stream)
                self._line_active = False
                self._line_width = 0
            counts = self.folder_status[folder]
            details = ", ".join(
                f"{counts[status]} {status.lower()}"
                for status in self._SUMMARY_ORDER
                if counts[status]
            )
            print(
                f"done {folder} {self.folder_done[folder]}/{self.folder_totals[folder]}"
                + (f" — {details}" if details else ""),
                file=self.stream,
            )

    def finish(self, complete: bool) -> None:
        if self._line_active:
            print(file=self.stream)
            self._line_active = False
        counts = Counter(
            status
            for statuses in self.folder_status.values()
            for status, count in statuses.items()
            for _ in range(count)
        )
        details = ", ".join(
            f"{counts[status]} {status.lower()}"
            for status in self._SUMMARY_ORDER
            if counts[status]
        )
        state = "complete" if complete else "interrupted"
        print(
            f"WPT {state}: {self.done}/{self.total} cases"
            + (f" — {details}" if details else ""),
            file=self.stream,
        )


def _free_loopback_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


class WptServer:
    """Own one worker-local WPT HTTP server for upstream testharness runs."""

    def __init__(self) -> None:
        self._process: subprocess.Popen[bytes] | None = None
        self._log: Any = None
        self._temporary_directory: tempfile.TemporaryDirectory[str] | None = None
        self.base_url: str | None = None

    def __enter__(self) -> str:
        self._temporary_directory = tempfile.TemporaryDirectory(
            prefix="zibra-wpt-"
        )
        config_path = pathlib.Path(self._temporary_directory.name) / "serve.json"
        port = _free_loopback_port()
        config_path.write_text(
            json.dumps(
                {
                    "browser_host": "127.0.0.1",
                    "alternate_hosts": {"alt": "127.0.0.2"},
                    "server_host": "127.0.0.1",
                    "doc_root": str(UPSTREAM),
                    "ports": {
                        "http": [port, "auto"],
                        "http-local": ["auto"],
                        "http-public": ["auto"],
                        "https": [],
                        "https-local": [],
                        "https-public": [],
                        "ws": [],
                        "wss": [],
                        "webtransport-h3": [],
                        "dns": [],
                    },
                    "check_subdomains": False,
                    "bind_address": True,
                }
            ),
            encoding="utf-8",
        )

        command = [sys.executable, str(UPSTREAM / "wpt")]
        venv = UPSTREAM / "_venv3"
        if venv.is_dir():
            command.extend(("--skip-venv-setup", "--venv", str(venv)))
        command.extend(
            (
                "serve",
                "--no-h2",
                "--config",
                str(config_path),
            )
        )
        self._log = tempfile.TemporaryFile(mode="w+b")
        try:
            self._process = subprocess.Popen(
                command,
                cwd=UPSTREAM,
                stdout=self._log,
                stderr=subprocess.STDOUT,
                start_new_session=(os.name == "posix"),
            )
            self.base_url = f"http://127.0.0.1:{port}"
            deadline = time.monotonic() + WPT_SERVER_STARTUP_TIMEOUT_SECONDS
            while time.monotonic() < deadline:
                if self._process.poll() is not None:
                    raise RuntimeError(
                        "WPT server exited during startup:\n" + self._read_log()
                    )
                try:
                    with urllib.request.urlopen(
                        self.base_url + "/", timeout=0.25
                    ):
                        return self.base_url
                except urllib.error.HTTPError:
                    # An HTTP response, including a 404, proves that the
                    # listener is ready; the selected path is checked later.
                    return self.base_url
                except (urllib.error.URLError, TimeoutError, OSError):
                    time.sleep(0.05)
            raise RuntimeError(
                "WPT server did not become ready within "
                f"{WPT_SERVER_STARTUP_TIMEOUT_SECONDS:.1f}s:\n{self._read_log()}"
            )
        except Exception:
            self.__exit__(None, None, None)
            raise

    def _read_log(self) -> str:
        if self._log is None:
            return "<no WPT server log>"
        self._log.seek(0)
        return self._log.read().decode("utf-8", errors="replace") or "<empty>"

    def __exit__(self, _type: Any, _value: Any, _traceback: Any) -> None:
        process = self._process
        if process is not None and process.poll() is None:
            try:
                if os.name == "posix":
                    os.killpg(os.getpgid(process.pid), signal.SIGTERM)
                else:
                    process.terminate()
                process.wait(timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                try:
                    if os.name == "posix":
                        os.killpg(os.getpgid(process.pid), signal.SIGKILL)
                    else:
                        process.kill()
                    process.wait(timeout=5)
                except (OSError, subprocess.TimeoutExpired):
                    pass
        self._process = None
        if self._log is not None:
            self._log.close()
            self._log = None
        if self._temporary_directory is not None:
            self._temporary_directory.cleanup()
            self._temporary_directory = None
        self.base_url = None


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


def _yaml_scalar(value: str, line_number: int) -> str | None:
    value = value.strip()
    if not value:
        raise ValueError(f"manifest line {line_number}: expected a value")
    if value in ("null", "~"):
        return None
    if value.startswith('"') and value.endswith('"'):
        try:
            decoded = json.loads(value)
        except json.JSONDecodeError as error:
            raise ValueError(f"manifest line {line_number}: invalid quoted value") from error
        if not isinstance(decoded, str):
            raise ValueError(f"manifest line {line_number}: value must be a string")
        return decoded
    if value.startswith("'") and value.endswith("'"):
        return value[1:-1].replace("''", "'")
    return value


def _strip_yaml_comment(line: str) -> str:
    quoted = False
    quote = ""
    for index, character in enumerate(line):
        if character in ("'", '"'):
            if quoted and character == quote:
                quoted = False
            elif not quoted:
                quoted = True
                quote = character
        elif character == "#" and not quoted and (index == 0 or line[index - 1].isspace()):
            return line[:index].rstrip()
    return line.rstrip()


def _load_yaml_config(path: pathlib.Path) -> dict[str, object]:
    """Parse the intentionally tiny YAML subset used by the WPT allowlist.

    Keeping this parser dependency-free makes the runner usable before WPT's
    optional Python environment is installed. The supported shape is a few
    top-level sections containing scalar path lists and a path-to-status map.
    """
    sections: dict[str, object] = {}
    list_sections = {"tests", "probes"}
    map_sections = {"deviations"}
    current: str | None = None
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = _strip_yaml_comment(raw_line)
        if not line.strip():
            continue
        if "\t" in line:
            raise ValueError(f"manifest line {line_number}: tabs are not supported")
        indent = len(line) - len(line.lstrip(" "))
        content = line.strip()
        if indent == 0:
            if not content.endswith(":"):
                raise ValueError(f"manifest line {line_number}: expected a section")
            key = content[:-1].strip()
            if key not in list_sections | map_sections:
                raise ValueError(f"manifest line {line_number}: unknown section {key!r}")
            current = key
            sections[key] = [] if key in list_sections else {}
            continue
        if current is None or indent != 2:
            raise ValueError(f"manifest line {line_number}: expected two-space indentation")
        if current in list_sections:
            if not content.startswith("- "):
                raise ValueError(f"manifest line {line_number}: expected a list item")
            value = _yaml_scalar(content[2:], line_number)
            if not isinstance(value, str) or not value:
                raise ValueError(f"manifest line {line_number}: path must be a string")
            sections[current].append(value)  # type: ignore[union-attr]
            continue
        if ":" not in content:
            raise ValueError(f"manifest line {line_number}: expected path: status")
        key, raw_value = content.split(":", 1)
        key = key.strip()
        value = _yaml_scalar(raw_value, line_number)
        if not key or not isinstance(value, str):
            raise ValueError(f"manifest line {line_number}: deviation must be path: status")
        sections[current][key] = value  # type: ignore[index]
    return sections


def _load_json_cases(path: pathlib.Path) -> list[Case]:
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


def load_cases(path: pathlib.Path) -> list[Case]:
    """Load the minimal YAML allowlist; retain JSON as a migration fallback."""
    if path.suffix.lower() == ".json":
        return _load_json_cases(path)
    config = _load_yaml_config(path)
    deviations = config.get("deviations", {})
    if not isinstance(deviations, dict):
        raise ValueError("manifest deviations must be a path-to-status map")
    cases: list[Case] = []
    for section, mode in (("tests", "testharness"), ("probes", "probe")):
        paths = config.get(section, [])
        if not isinstance(paths, list):
            raise ValueError(f"manifest {section} must be a list")
        for path_value in paths:
            expectation = deviations.get(path_value)
            if expectation is not None and not isinstance(expectation, str):
                raise ValueError(f"manifest deviation for {path_value!r} must be a status")
            case = Case(
                path=path_value,
                mode=mode,
                status="candidate",
                reason="Selected by the WPT YAML allowlist.",
                expectation=expectation,
            )
            _validate_case(case, len(cases))
            cases.append(case)
    unknown_deviations = set(deviations) - {case.path for case in cases}
    if unknown_deviations:
        names = ", ".join(sorted(unknown_deviations))
        raise ValueError(f"manifest deviations refer to unselected tests: {names}")
    return cases


def discover_testharness_cases() -> list[Case]:
    """Discover upstream files that embed the WPT testharness protocol.

    This intentionally excludes WPT support files and non-test resources. It
    does not claim that every discovered file is runnable: an individual test
    can still fail or be classified as ``INFRA`` by the browser protocol.
    Keeping discovery convention-based means the full corpus needs no
    hand-maintained manifest.
    """
    if not UPSTREAM.is_dir():
        return []
    cases: list[Case] = []
    for path in sorted(UPSTREAM.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in DISCOVERY_EXTENSIONS:
            continue
        relative = path.relative_to(UPSTREAM).as_posix()
        if relative.startswith(DISCOVERY_SKIP_PREFIXES):
            continue
        try:
            source = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        if "testharness.js" not in source and "testharnessreport.js" not in source:
            continue
        cases.append(
            Case(
                path=relative,
                mode="testharness",
                status="discovered",
                reason="Discovered by testharness convention.",
            )
        )
    return cases


def _invoke(command: list[str], watchdog_seconds: float) -> ProcessOutcome:
    process: subprocess.Popen[str] | None = None
    try:
        process = subprocess.Popen(
            command,
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=(os.name == "posix"),
        )
        stdout, stderr = process.communicate(timeout=watchdog_seconds)
    except subprocess.TimeoutExpired:
        # A browser can create child processes (or leave helper threads that
        # own descendants). Kill the process group so a single bad test cannot
        # leak work into later cases or keep the runner alive indefinitely.
        if process is not None:
            try:
                if os.name == "posix":
                    os.killpg(os.getpgid(process.pid), signal.SIGKILL)
                else:
                    process.kill()
                stdout, stderr = process.communicate()
            except (OSError, subprocess.TimeoutExpired):
                stdout, stderr = "", ""
        return ProcessOutcome(
            stdout=_as_text(stdout),
            stderr=_as_text(stderr),
            infrastructure_error=(
                f"browser watchdog expired after {watchdog_seconds:.3f} seconds"
            ),
        )
    except OSError as error:
        if process is not None and process.poll() is None:
            try:
                if os.name == "posix":
                    os.killpg(os.getpgid(process.pid), signal.SIGKILL)
                else:
                    process.kill()
                process.communicate(timeout=1)
            except (OSError, subprocess.TimeoutExpired):
                pass
        return ProcessOutcome(
            stdout="",
            stderr="",
            infrastructure_error=f"failed to start browser: {error}",
        )

    if process.returncode != 0:
        return ProcessOutcome(
            stdout=stdout,
            stderr=stderr,
            infrastructure_error=f"browser exited with status {process.returncode}",
        )
    return ProcessOutcome(stdout=stdout, stderr=stderr)


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
            encoded = value.encode("utf-8")
            if len(encoded) > MAX_CONSOLE_DIAGNOSTIC_BYTES:
                value = (
                    encoded[:MAX_CONSOLE_DIAGNOSTIC_BYTES]
                    .decode("utf-8", errors="replace")
                    + "\n[diagnostic preview truncated; full output is in the report]\n"
                )
            sys.stderr.write(value)
            if not value.endswith("\n"):
                sys.stderr.write("\n")
        else:
            print("<empty>", file=sys.stderr)


def _run_probe(case: Case, url: str, browser: list[str]) -> CaseResult:
    watchdog_seconds = case.timeout_ms / 1000 + WATCHDOG_GRACE_SECONDS
    outcome = _invoke([*browser, "--dump-dom", url], watchdog_seconds)
    if outcome.infrastructure_error is not None:
        return CaseResult(
            case=case,
            status="INFRA",
            ok=False,
            infrastructure_error=outcome.infrastructure_error,
            stdout=outcome.stdout,
            stderr=outcome.stderr,
        )
    return CaseResult(case=case, status="PROBE", ok=True)


def _run_testharness(case: Case, url: str, browser: list[str]) -> CaseResult:
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
        return CaseResult(
            case=case,
            status="INFRA",
            ok=False,
            infrastructure_error=outcome.infrastructure_error,
            stdout=outcome.stdout,
            stderr=outcome.stderr,
        )

    try:
        record = parse_testharness_result(outcome.stdout, url)
    except ValueError as error:
        return CaseResult(
            case=case,
            status="INFRA",
            ok=False,
            infrastructure_error=str(error),
            stdout=outcome.stdout,
            stderr=outcome.stderr,
        )

    actual = record["status"]
    expected = case.expected_status
    if actual != expected:
        return CaseResult(
            case=case,
            status=actual,
            ok=False,
            record=record,
            stdout=outcome.stdout,
            stderr=outcome.stderr,
        )
    return CaseResult(
        case=case,
        status=actual,
        ok=True,
        record=record,
        stdout=outcome.stdout,
        stderr=outcome.stderr,
    )


def _bounded_diagnostic(value: str) -> str:
    if len(value.encode("utf-8")) <= MAX_DIAGNOSTIC_BYTES:
        return value
    encoded = value.encode("utf-8")[:MAX_DIAGNOSTIC_BYTES]
    return encoded.decode("utf-8", errors="replace") + "\n[truncated]"


def _browser_revision() -> str:
    """Return a display-safe revision, tolerating old task-shell artifacts."""
    value = (
        os.environ.get("ZIBRA_GIT_SHA")
        or os.environ.get("GITHUB_SHA")
        or os.environ.get("CI_COMMIT_SHA")
        or "working-tree"
    ).strip()
    if "git rev-parse" in value or "printf working-tree" in value:
        match = re.match(r"^([0-9a-f]{4,40})", value, re.IGNORECASE)
        return match.group(1) if match else "working-tree"
    return value


def _serialize_case_result(result: CaseResult) -> dict[str, Any]:
    case = result.case
    item: dict[str, Any] = {
        "path": case.path,
        "mode": case.mode,
        "status": result.status,
        "ok": result.ok,
        "expected": case.expected_status if not case.skipped else "SKIP",
        "expectation": case.expectation,
        "timeout_ms": case.timeout_ms,
    }
    if result.record is not None:
        for key in ("duration_ms", "tests", "harness", "message", "console", "exception"):
            if key in result.record:
                item[key] = result.record[key]
    if result.infrastructure_error is not None:
        item["infrastructure_error"] = result.infrastructure_error
    if not result.ok or result.infrastructure_error is not None:
        if result.stdout:
            item["stdout"] = _bounded_diagnostic(result.stdout)
        if result.stderr:
            item["stderr"] = _bounded_diagnostic(result.stderr)
    return item


def write_run_report(
    path: pathlib.Path,
    *,
    manifest: pathlib.Path,
    mode: str,
    browser: list[str],
    started_at: datetime,
    finished_at: datetime,
    results: list[CaseResult],
    complete: bool = True,
    expected_cases: int | None = None,
) -> None:
    serialized = [_serialize_case_result(result) for result in results]
    counts = Counter(item["status"] for item in serialized)
    subtest_counts = Counter(
        subtest.get("status")
        for item in serialized
        for subtest in item.get("tests", [])
        if isinstance(subtest, dict)
    )
    report = {
        "schema_version": REPORT_SCHEMA_VERSION,
        "run_id": finished_at.strftime("%Y%m%dT%H%M%S.%fZ"),
        "started_at": started_at.isoformat().replace("+00:00", "Z"),
        "finished_at": finished_at.isoformat().replace("+00:00", "Z"),
        "complete": complete,
        "expected_cases": expected_cases if expected_cases is not None else len(serialized),
        "manifest": str(manifest),
        "suite": "all" if str(manifest) == "<all-testharness>" else "focused",
        "mode": mode,
        "browser": browser,
        "browser_revision": _browser_revision(),
        "summary": {
            "total": len(serialized),
            "pass": counts["PASS"],
            "fail": counts["FAIL"],
            "error": counts["ERROR"],
            "timeout": counts["TIMEOUT"],
            "infra": counts["INFRA"],
            "probe": counts["PROBE"],
            "skip": counts["SKIP"],
            # Keep the case-level counts above for ordinary WPT runs, while
            # also exposing the granular score used by suites such as Acid3,
            # whose numbered tests are subtests of one harness page.
            "subtests_total": sum(subtest_counts.values()),
            "subtests_pass": subtest_counts["PASS"],
            "subtests_fail": subtest_counts["FAIL"],
            "subtests_error": subtest_counts["ERROR"],
            "subtests_timeout": subtest_counts["TIMEOUT"],
        },
        "tests": serialized,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def _parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "manifest", nargs="?", type=pathlib.Path, default=DEFAULT_MANIFEST
    )
    parser.add_argument("--list", action="store_true", help="list manifest entries")
    parser.add_argument(
        "--mode", choices=("probe", "testharness"),
        help="manifest case mode (defaults to testharness with --all, probe otherwise)",
    )
    parser.add_argument(
        "--all", action="store_true",
        help="discover and run all upstream testharness cases (no manifest needed)",
    )
    parser.add_argument(
        "--jobs", type=int, default=1,
        help="maximum browser processes to run concurrently (default: 1)",
    )
    parser.add_argument(
        "--browser",
        nargs="+",
        default=["zig", "build", "run", "--"],
        help="command prefix used to invoke Zibra (default: zig build run --)",
    )
    parser.add_argument(
        "--report",
        type=pathlib.Path,
        help="write a durable JSON run report for the local dashboard",
    )
    parser.add_argument(
        "--timeout-ms",
        type=int,
        help="override the manifest timeout for every selected case",
    )
    parser.add_argument(
        "--checkpoint-every", type=int, default=25,
        help="write an in-progress report every N completed cases (0 disables it)",
    )
    parser.add_argument(
        "--verbose", action="store_true",
        help="include browser diagnostics for failed cases on stderr",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    mode = args.mode or ("testharness" if args.all else "probe")
    if args.all and args.mode == "probe":
        print("--all only supports --mode testharness", file=sys.stderr)
        return 2
    if args.jobs <= 0:
        print("--jobs must be a positive integer", file=sys.stderr)
        return 2
    if args.checkpoint_every < 0:
        print("--checkpoint-every must be zero or a positive integer", file=sys.stderr)
        return 2
    if args.timeout_ms is not None and args.timeout_ms <= 0:
        print("--timeout-ms must be a positive integer", file=sys.stderr)
        return 2
    manifest_for_report = args.manifest
    if args.all:
        cases = discover_testharness_cases()
        manifest_for_report = pathlib.Path("<all-testharness>")
        print(f"Discovered {len(cases)} testharness cases")
    else:
        try:
            cases = load_cases(args.manifest)
        except (OSError, json.JSONDecodeError, ValueError) as error:
            print(f"Failed to load WPT manifest: {error}", file=sys.stderr)
            return 2

    if args.list:
        try:
            for case in cases:
                claim = "skip" if case.skipped else case.expectation or case.status
                print(f"{claim:9} {case.mode:11} {case.path}  # {case.reason}")
        except BrokenPipeError:
            # `--all --list | head` is a common way to inspect discovery.
            # Avoid turning the closed pipe into a failed runner invocation.
            sys.stdout = open(os.devnull, "w")
        return 0

    started_at = datetime.now(timezone.utc)

    if not UPSTREAM.is_dir():
        print(
            "WPT checkout missing; run the git submodule commands in tests/wpt/README.md.",
            file=sys.stderr,
        )
        return 2

    selected: list[tuple[Case, pathlib.Path]] = []
    results: list[CaseResult] = []
    failed = 0
    for case in cases:
        if case.skipped:
            results.append(CaseResult(case=case, status="SKIP", ok=True))
            continue
        if case.mode != mode:
            continue
        test_path = (UPSTREAM / case.path).resolve()
        if not test_path.is_file():
            if case.mode == "probe":
                results.append(CaseResult(case=case, status="SKIP", ok=True))
            else:
                failed += 1
                results.append(
                    CaseResult(
                        case=case,
                        status="INFRA",
                        ok=False,
                        infrastructure_error="missing from checkout",
                    )
                )
            continue
        selected.append((case, test_path))

    progress_cases = [result.case for result in results]
    progress_cases.extend(case for case, _ in selected)
    reporter = ProgressReporter(progress_cases, mode, args.jobs)
    reporter.start()
    for result in results:
        reporter.record(result)

    # Upstream testharness files use root-relative /resources URLs. Serve
    # them through WPT's own HTTP server so URL resolution, MIME types, and
    # future dynamic handlers match the environment the tests expect. The
    # temporary fake checkouts used by runner unit tests have no `wpt` command,
    # so they retain the deterministic file-URL path.
    server_context: WptServer | None = None
    server_base_url: str | None = None
    if mode == "testharness" and selected and (UPSTREAM / "wpt").is_file():
        server_context = WptServer()
        try:
            server_base_url = server_context.__enter__()
        except Exception as error:
            print(f"WPT server failed: {error}", file=sys.stderr)
            if server_context is not None:
                server_context.__exit__(type(error), error, error.__traceback__)
            if args.report:
                write_run_report(
                    args.report,
                    manifest=manifest_for_report,
                    mode=mode,
                    browser=args.browser,
                    started_at=started_at,
                    finished_at=datetime.now(timezone.utc),
                    results=results,
                    complete=False,
                    expected_cases=len(results) + len(selected),
                )
            reporter.finish(False)
            return 1

    def run_one(item: tuple[Case, pathlib.Path]) -> CaseResult:
        case, test_path = item
        run_case = replace(case, timeout_ms=args.timeout_ms) if args.timeout_ms is not None else case
        if server_base_url is None:
            url = test_path.as_uri()
        else:
            relative_path = test_path.relative_to(UPSTREAM).as_posix()
            url = f"{server_base_url}/{relative_path}"
        try:
            if run_case.mode == "probe":
                return _run_probe(run_case, url, args.browser)
            return _run_testharness(run_case, url, args.browser)
        except Exception as error:
            # A malformed browser response is handled above. This catches
            # unexpected runner failures as an isolated infrastructure result
            # instead of losing all results from a multi-hour batch.
            message = f"runner worker raised {type(error).__name__}: {error}"
            return CaseResult(
                case=run_case,
                status="INFRA",
                ok=False,
                infrastructure_error=message,
            )

    def handle_result(result: CaseResult) -> None:
        reporter.record(result)
        if args.verbose and (not result.ok or result.infrastructure_error is not None):
            if result.infrastructure_error is not None:
                print(
                    f"INFRA {result.case.path}: {result.infrastructure_error}",
                    file=sys.stderr,
                )
            _write_raw_diagnostics(
                ProcessOutcome(stdout=result.stdout, stderr=result.stderr)
            )

    completed: dict[int, CaseResult] = {}
    run_complete = False

    def report_snapshot() -> None:
        if args.report is None:
            return
        write_run_report(
            args.report,
            manifest=manifest_for_report,
            mode=mode,
            browser=args.browser,
            started_at=started_at,
            finished_at=datetime.now(timezone.utc),
            results=[*results, *(completed[index] for index in sorted(completed))],
            complete=False,
            expected_cases=len(results) + len(selected),
        )

    try:
        if args.jobs == 1 or len(selected) <= 1:
            for index, item in enumerate(selected):
                completed[index] = run_one(item)
                handle_result(completed[index])
                if not completed[index].ok:
                    failed += 1
                if args.checkpoint_every and len(completed) % args.checkpoint_every == 0:
                    report_snapshot()
        else:
            # Keep only a small queue of futures. Besides reducing memory for
            # a 28k-case run, this makes Ctrl-C responsive instead of leaving
            # thousands of already-queued browser invocations to drain.
            executor = ThreadPoolExecutor(
                max_workers=args.jobs, thread_name_prefix="zibra-wpt"
            )
            pending: dict[Any, int] = {}
            next_index = 0
            try:
                while next_index < len(selected) and len(pending) < args.jobs:
                    pending[executor.submit(run_one, selected[next_index])] = next_index
                    next_index += 1
                while pending:
                    done, _ = wait(pending, return_when=FIRST_COMPLETED)
                    for future in done:
                        index = pending.pop(future)
                        completed[index] = future.result()
                        handle_result(completed[index])
                        if not completed[index].ok:
                            failed += 1
                        if args.checkpoint_every and len(completed) % args.checkpoint_every == 0:
                            report_snapshot()
                    while next_index < len(selected) and len(pending) < args.jobs:
                        pending[executor.submit(run_one, selected[next_index])] = next_index
                        next_index += 1
            except BaseException:
                for future in pending:
                    future.cancel()
                executor.shutdown(wait=False, cancel_futures=True)
                raise
            else:
                executor.shutdown(wait=True)
        results.extend(completed[index] for index in sorted(completed))
        run_complete = True
    finally:
        if server_context is not None:
            server_context.__exit__(None, None, None)
        if args.report:
            report_results = (
                results
                if run_complete
                else [*results, *(completed[index] for index in sorted(completed))]
            )
            write_run_report(
                args.report,
                manifest=manifest_for_report,
                mode=mode,
                browser=args.browser,
                started_at=started_at,
                finished_at=datetime.now(timezone.utc),
                results=report_results,
                complete=run_complete,
                expected_cases=(
                    len(report_results)
                    if run_complete
                    else len(results) + len(selected)
                ),
            )
        reporter.finish(run_complete)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
