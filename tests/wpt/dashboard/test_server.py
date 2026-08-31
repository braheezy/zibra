#!/usr/bin/env python3
"""Small dependency-free tests for the local dashboard API."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location("zibra_wpt_dashboard", Path(__file__).with_name("server.py"))
server = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(server)


class DashboardServerTests(unittest.TestCase):
    def test_run_summary_and_path_safety(self):
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory)
            report = {
                "schema_version": 1,
                "run_id": "run-1",
                "finished_at": "2026-01-01T00:00:00Z",
                "mode": "testharness",
                "browser_revision": "abc1234",
                "summary": {"total": 1, "pass": 1},
                "tests": [{"path": "dom/example.html", "status": "PASS"}],
            }
            (results / "run-1.json").write_text(json.dumps(report), encoding="utf-8")
            with mock.patch.object(server, "RESULTS", results):
                summaries = server._run_files()
                self.assertEqual([results / "run-1.json"], summaries)
                summary = server._run_summary(summaries[0])
                self.assertEqual("run-1", summary["id"])
                self.assertEqual("abc1234", summary["browser_revision"])


if __name__ == "__main__":
    unittest.main()
