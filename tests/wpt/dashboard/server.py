#!/usr/bin/env python3
"""Serve the local Zibra WPT dashboard and its immutable run artifacts."""

from __future__ import annotations

import json
import os
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse


ROOT = Path(__file__).resolve().parent
STATIC = ROOT / "static"
RESULTS = Path(os.environ.get("RESULTS_DIR", "/data"))
WPT_CHECKOUT = Path(os.environ.get("WPT_DIR", "/wpt"))


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


def _run_summary(path: Path) -> dict:
    report = _read_run(path)
    summary = report.get("summary", {})
    return {
        "id": path.stem,
        "run_id": report.get("run_id", path.stem),
        "started_at": report.get("started_at"),
        "finished_at": report.get("finished_at"),
        "mode": report.get("mode"),
        "browser_revision": report.get("browser_revision", "working-tree"),
        "summary": summary if isinstance(summary, dict) else {},
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
            self.path = "/index.html"
            if parsed.query:
                self.path += "?" + parsed.query
            super().do_GET()
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
