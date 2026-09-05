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
                "manifest": "<all-testharness>",
                "browser_revision": "abc1234",
                "inventory": {
                    "total": 118858,
                    "runnable": 33982,
                    "categories": {"testharness": 33982},
                },
                "summary": {"total": 1, "pass": 1},
                "tests": [
                    {"path": "dom/example.html", "status": "PASS"},
                    {
                        "path": "dom/subtests.html",
                        "status": "PASS",
                        "tests": [
                            {"name": "one", "status": "PASS"},
                            {"name": "two", "status": "FAIL"},
                        ],
                    },
                ],
            }
            (results / "run-1.json").write_text(json.dumps(report), encoding="utf-8")
            with mock.patch.object(server, "RESULTS", results):
                summaries = server._run_files()
                self.assertEqual([results / "run-1.json"], summaries)
                summary = server._run_summary(summaries[0])
                self.assertEqual("run-1", summary["id"])
                self.assertEqual("abc1234", summary["browser_revision"])
                self.assertTrue(summary["full_suite"])
                self.assertEqual(118858, summary["inventory"]["total"])
                self.assertEqual(
                    [{"path": "dom/", "passed": 2, "total": 3}],
                    summary["directories"],
                )

    def test_focused_manifest_is_not_a_full_suite_run(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "focused.json"
            path.write_text(
                json.dumps({"manifest": "tests/wpt/manifest-dom.yaml", "tests": []}),
                encoding="utf-8",
            )
            self.assertFalse(server._run_summary(path)["full_suite"])

    def test_explicit_scores_preserve_unselected_directories(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "coverage.json"
            path.write_text(
                json.dumps(
                    {
                        "manifest": "tests/wpt/manifest.yaml",
                        "suite": "all",
                        "summary": {"suite_failed": True},
                        "directory_scores": [
                            {
                                "path": "accelerometer/",
                                "passed": 0,
                                "total": 4,
                                "skipped": 4,
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            summary = server._run_summary(path)
            self.assertTrue(summary["full_suite"])
            self.assertEqual(
                [{"path": "accelerometer/", "passed": 0, "total": 4, "skipped": 4}],
                summary["directories"],
            )

    def test_run_summary_sanitizes_legacy_revision_text(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "legacy.json"
            path.write_text(
                json.dumps({
                    "browser_revision": "9476(git rev-parse --short HEAD)",
                    "tests": [],
                }),
                encoding="utf-8",
            )
            self.assertEqual("9476", server._run_summary(path)["browser_revision"])


if __name__ == "__main__":
    unittest.main()
