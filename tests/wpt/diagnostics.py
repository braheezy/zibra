"""Bounded WPT observations, independent of semantic result classification.

The browser writes optional JSON events on stderr so startup failures and
watchdog kills retain evidence even without a terminal protocol record. Older
binaries still get conservative diagnoses from their existing logs.
"""

import json
import re
from urllib.parse import urlsplit


EVENT_PREFIX = "info: ZIBRA_WPT_DIAGNOSTIC "
MAX_EVENTS = 128
MAX_EVENT_BYTES = 8192
MAX_ERRORS = 8
MAX_PARTIAL_RESULTS = 8
EVENT_KINDS = {
    "session-started", "runtime-ready", "harness-ready", "harness-started",
    "subtest-complete", "script-error", "truncated",
}


def analyze_testharness(path, url, stderr, record=None, *, watchdog=False):
    event_count = 0
    errors = []
    legacy_errors = []
    partial = []
    hints = set()
    runtime_ready = False
    session_started = False
    harness_ready = False
    harness_started = False
    completed = 0
    truncated = False
    malformed_events = 0
    interrupted = False

    # Preserve Unicode line separators inside event JSON and error messages.
    for line in stderr.split("\n"):
        if line.startswith(EVENT_PREFIX):
            text = line[len(EVENT_PREFIX):]
            if len(text.encode("utf-8")) > MAX_EVENT_BYTES:
                truncated = True
                continue
            try:
                event = json.loads(text)
            except ValueError:
                malformed_events += 1
                continue
            if not isinstance(event, dict):
                malformed_events += 1
                continue
            kind = event.get("kind")
            if not isinstance(kind, str) or kind not in EVENT_KINDS:
                malformed_events += 1
                continue
            if kind == "subtest-complete" and (
                type(event.get("completed")) is not int or event["completed"] < 1
                or not isinstance(event.get("name"), str)
                or event.get("status") not in ("PASS", "FAIL", "TIMEOUT", "NOTRUN", "PRECONDITION_FAILED")
            ):
                malformed_events += 1
                continue
            if kind == "script-error" and not isinstance(event.get("error_kind"), str):
                malformed_events += 1
                continue
            event_count += 1
            # Progress sampling cannot consume the space reserved for errors.
            if event_count > MAX_EVENTS and kind != "script-error":
                truncated = True
                continue
            session_started |= kind == "session-started"
            runtime_ready |= kind == "runtime-ready"
            harness_ready |= kind in ("harness-ready", "harness-started", "subtest-complete")
            harness_started |= kind in ("harness-started", "subtest-complete")
            truncated |= kind == "truncated"
            if kind == "script-error":
                interrupted |= event.get("error_kind") == "ExecutionInterrupted"
                if len(errors) < MAX_ERRORS:
                    errors.append(event)
                else:
                    truncated = True
            if kind == "subtest-complete":
                count = event.get("completed")
                completed = max(completed, count)
                if len(partial) < MAX_PARTIAL_RESULTS:
                    partial.append(event)
        elif line.startswith("error: Parser script ") and " crashed: error." in line:
            match = re.match(r"error: Parser script (.*?) \(\d+ bytes\) crashed: error\.(\w+)", line)
            if match:
                interrupted |= match[2] == "ExecutionInterrupted"
                if len(legacy_errors) < MAX_ERRORS:
                    legacy_errors.append({"source": match[1][:512], "error_kind": match[2]})
                else:
                    truncated = True
        if line.startswith("info: GET ") and "/resources/testdriver" in line:
            hints.add("testdriver")

    if ".worker." in path or ".sharedworker." in path or ".serviceworker." in path:
        hints.add("worker")
    if urlsplit(path).path.endswith(".svg"):
        hints.add("svg-document")
    if not errors:
        errors = legacy_errors

    status = record.get("status") if record else None
    harness_reported = isinstance(record.get("harness"), dict) if record else False
    timeout_kind = None
    if watchdog:
        timeout_kind = "watchdog"
    elif status == "TIMEOUT":
        timeout_kind = "harness" if harness_reported else "session-deadline"
    reason = None
    if watchdog:
        reason = "watchdog-expired"
    elif status == "TIMEOUT":
        if harness_reported:
            reason = "harness-timeout"
        elif interrupted:
            reason = "execution-interrupted"
        elif errors:
            reason = "script-error"
        elif urlsplit(url).path.endswith(".js"):
            reason = "wrong-entry-url"
        elif harness_ready:
            reason = "completion-pending"
        elif runtime_ready:
            reason = "harness-not-observed"
        elif session_started:
            reason = "runtime-not-observed"
        else:
            reason = "unknown"

    return {
        "timeout_kind": timeout_kind,
        "reason": reason,
        "runtime_ready_observed": runtime_ready,
        "session_started_observed": session_started,
        "harness_ready_observed": harness_ready,
        "harness_started_observed": harness_started,
        "completed_subtests_observed": completed,
        # Samples are diagnostic evidence, not a replacement for record.tests.
        "partial_subtests": partial,
        "script_errors": errors,
        "prerequisite_hints": sorted(hints),
        "events_truncated": truncated,
        "malformed_events": malformed_events,
    }
