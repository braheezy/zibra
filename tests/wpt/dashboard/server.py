#!/usr/bin/env python3
"""Serve the local Zibra WPT dashboard and its immutable run artifacts."""

from __future__ import annotations

import json
import os
import re
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse


ROOT = Path(__file__).resolve().parent
STATIC = ROOT / "static"
RESULTS = Path(os.environ.get("RESULTS_DIR", "/data"))
WPT_CHECKOUT = Path(os.environ.get("WPT_DIR", "/wpt"))


def _revision_label(value: object) -> str:
    """Keep shell fragments from old reports out of dashboard metadata."""
    text = str(value or "working-tree").strip()
    if "git rev-parse" in text or "printf working-tree" in text:
        match = re.match(r"^([0-9a-f]{4,40})", text, re.IGNORECASE)
        return match.group(1) if match else "working-tree"
    return text


def _run_files() -> list[Path]:
    if not RESULTS.is_dir():
        return []
    return sorted(
        (path for path in RESULTS.glob("*.json") if path.is_file()),
        key=lambda path: path.stat().st_mtime_ns,
        reverse=True,
    )


def _read_run(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def _directory_scores(report: dict) -> list[dict[str, object]]:
    """Collapse case records into the directory scores used by the UI."""
    groups: dict[str, dict[str, int]] = {}
    tests = report.get("tests", [])
    if not isinstance(tests, list):
        return []
    for test in tests:
        if not isinstance(test, dict):
            continue
        path = str(test.get("path", ""))
        parts = [part for part in path.split("/") if part]
        group = f"{parts[0]}/" if len(parts) > 1 else "(root)"
        item = groups.setdefault(group, {"passed": 0, "total": 0})
        subtests = test.get("tests", [])
        if isinstance(subtests, list) and subtests:
            item["passed"] += sum(
                1
                for subtest in subtests
                if isinstance(subtest, dict) and subtest.get("status") == "PASS"
            )
            item["total"] += len(subtests)
        else:
            item["passed"] += int(test.get("status") == "PASS")
            item["total"] += 1
    return [
        {"path": path, **groups[path]}
        for path in sorted(groups)
    ]


def _run_summary(path: Path) -> dict:
    report = _read_run(path)
    summary = report.get("summary", {})
    manifest = report.get("manifest")
    suite = report.get("suite")
    return {
        "id": path.stem,
        "run_id": report.get("run_id", path.stem),
        "started_at": report.get("started_at"),
        "finished_at": report.get("finished_at"),
        "mode": report.get("mode"),
        "manifest": manifest,
        # Focused manifests are useful for debugging, but mixing their scores
        # into the history makes progress look artificially better as the
        # selected set changes. The chart therefore consumes full-suite runs.
        "full_suite": suite == "all" or manifest == "<all-testharness>",
        "browser_revision": _revision_label(report.get("browser_revision")),
        "summary": summary if isinstance(summary, dict) else {},
        "directories": _directory_scores(report),
    }


class DashboardHandler(SimpleHTTPRequestHandler):
    """Static files plus a deliberately read-only run-artifact API."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(STATIC), **kwargs)

    def _json(self, value: object, status: HTTPStatus = HTTPStatus.OK) -> None:
        payload = json.dumps(value, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:  # noqa: N802 - stdlib handler API
        parsed = urlparse(self.path)
        # Be explicit about the dashboard entry point.  This avoids falling
        # back to SimpleHTTPRequestHandler's directory index when the server
        # is launched from a copied container filesystem or through a URL
        # that omits the trailing slash.
        if parsed.path in ("", "/"):
            # Serve the entry point directly instead of delegating to
            # SimpleHTTPRequestHandler, whose directory-listing fallback can
            # appear when a stale/copy-mounted static directory is missing
            # its index metadata.
            index = STATIC / "index.html"
            try:
                payload = index.read_bytes()
            except OSError:
                self._json({"error": "dashboard index unavailable"}, HTTPStatus.INTERNAL_SERVER_ERROR)
                return
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(payload)
            return
        if parsed.path == "/api/health":
            self._json({"ok": True})
            return
        if parsed.path == "/api/info":
            self._json(
                {
                    "results_dir": str(RESULTS),
                    "wpt_checkout_present": WPT_CHECKOUT.is_dir(),
                    "run_count": len(_run_files()),
                }
            )
            return
        if parsed.path == "/api/runs":
            self._json({"schema_version": 1, "runs": [_run_summary(path) for path in _run_files()]})
            return
        prefix = "/api/runs/"
        if parsed.path.startswith(prefix):
            name = unquote(parsed.path[len(prefix) :])
            if not name or Path(name).name != name or not name.endswith(".json"):
                self._json({"error": "invalid run id"}, HTTPStatus.BAD_REQUEST)
                return
            path = RESULTS / name
            if not path.is_file():
                self._json({"error": "run not found"}, HTTPStatus.NOT_FOUND)
                return
            report = _read_run(path)
            if not report:
                self._json({"error": "invalid run report"}, HTTPStatus.UNPROCESSABLE_ENTITY)
                return
            self._json(report)
            return
        super().do_GET()


def main() -> None:
    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", "8188"))
    server = ThreadingHTTPServer((host, port), DashboardHandler)
    print(f"Zibra WPT dashboard listening on http://{host}:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
