import contextlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest import mock
import zlib


SPEC = importlib.util.spec_from_file_location(
    "zibra_wpt_runner", Path(__file__).with_name("run.py")
)
runner = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = runner
SPEC.loader.exec_module(runner)


class WptRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.upstream = self.root / "upstream"
        self.upstream.mkdir()
        self.case_path = "dom/example.html"
        test_file = self.upstream / self.case_path
        test_file.parent.mkdir()
        test_file.write_text("<!doctype html><title>fixture</title>", encoding="utf-8")

    def tearDown(self):
        self.temporary_directory.cleanup()

    def test_jsonl_preserves_unicode_line_separators_and_strict_framing(self):
        record = {"protocol_version": 1, "test": "file:///fixture", "status": "PASS",
                  "duration_ms": 1, "message": "A\u0085B\u2028C\u2029D"}
        payload = json.dumps(record, ensure_ascii=False)
        for ending in ("", "\n", "\r\n"):
            with self.subTest(ending=ending):
                self.assertEqual(record, runner.parse_testharness_result(payload + ending, record["test"]))
        for text in (payload + "\n\n", payload + "\n" + payload, "noise\n" + payload,
                     "", "\n", "{} {}", "[]"):
            with self.subTest(text=text):
                with self.assertRaises(ValueError):
                    runner.parse_testharness_result(text, record["test"])

    def diagnostic_lines(self, *events):
        return "".join("info: ZIBRA_WPT_DIAGNOSTIC " + json.dumps(event, ensure_ascii=False) + "\n" for event in events)

    def test_timeout_observations_keep_partial_results_and_script_error_details(self):
        stderr = self.diagnostic_lines(
            {"kind": "runtime-ready"}, {"kind": "harness-ready"},
            {"kind": "subtest-complete", "completed": 1, "name": "passed already", "status": "PASS"},
            {"kind": "script-error", "source": "setup.js", "error_kind": "ExceptionThrown", "detail": "Error: broken\n  at setup\u2028line"},
        )
        record = {"protocol_version": 1, "test": "file:///fixture", "status": "TIMEOUT",
                  "duration_ms": 10000, "harness": None, "tests": []}
        case = runner.Case("dom/fixture.html", "testharness", "diagnostics")
        with mock.patch.object(runner, "_invoke", return_value=runner.ProcessOutcome(json.dumps(record), stderr)):
            result = runner._run_testharness(case, record["test"], ["unused"])
        self.assertEqual("TIMEOUT", result.status)
        self.assertFalse(result.ok)
        self.assertEqual([], result.record["tests"])
        diagnostic = runner._serialize_case_result(result)["diagnostics"]
        self.assertEqual("session-deadline", diagnostic["timeout_kind"])
        self.assertEqual("script-error", diagnostic["reason"])
        self.assertEqual(1, diagnostic["completed_subtests_observed"])
        self.assertEqual("passed already", diagnostic["partial_subtests"][0]["name"])
        self.assertIn("setup\u2028line", diagnostic["script_errors"][0]["detail"])

    def test_diagnostics_distinguish_deadlines_harness_timeouts_and_watchdogs(self):
        ready = self.diagnostic_lines({"kind": "runtime-ready"}, {"kind": "harness-ready"})
        cases = [
            ("", None, False, "unknown", "session-deadline"),
            (self.diagnostic_lines({"kind": "runtime-ready"}), None, False, "harness-not-observed", "session-deadline"),
            (ready, None, False, "completion-pending", "session-deadline"),
            (ready, {"status": "TIMEOUT"}, False, "harness-timeout", "harness"),
            (ready, None, True, "watchdog-expired", "watchdog"),
            (self.diagnostic_lines({"kind": "script-error", "error_kind": "ExecutionInterrupted"}), None, False, "execution-interrupted", "session-deadline"),
        ]
        for stderr, harness, watchdog, reason, kind in cases:
            with self.subTest(reason=reason):
                diagnostic = runner.analyze_testharness("dom/test.html", "file:///test.html", stderr,
                    None if watchdog else {"status": "TIMEOUT", "harness": harness}, watchdog=watchdog)
                self.assertEqual(reason, diagnostic["reason"])
                self.assertEqual(kind, diagnostic["timeout_kind"])

    def test_diagnostic_errors_cannot_override_valid_harness_completion(self):
        stderr = self.diagnostic_lines({"kind": "script-error", "error_kind": "ExceptionThrown", "detail": "expected by test"})
        case = runner.Case("dom/test.html", "testharness", "fixture")
        record = {"protocol_version": 1, "test": "file:///test", "status": "PASS", "duration_ms": 1}
        with mock.patch.object(runner, "_invoke", return_value=runner.ProcessOutcome(json.dumps(record), stderr)):
            result = runner._run_testharness(case, record["test"], ["unused"])
        self.assertTrue(result.ok)
        self.assertIsNone(result.diagnostics["reason"])
        self.assertEqual(1, len(result.diagnostics["script_errors"]))

    def test_watchdog_is_infra_with_distinct_diagnostics_and_progress_label(self):
        outcome = runner.ProcessOutcome("", "", infrastructure_error="watchdog expired", watchdog_expired=True)
        case = runner.Case("dom/test.html", "testharness", "fixture")
        with mock.patch.object(runner, "_invoke", return_value=outcome):
            result = runner._run_testharness(case, "file:///test", ["unused"])
        self.assertEqual("INFRA", result.status)
        self.assertEqual("watchdog", result.diagnostics["timeout_kind"])
        self.assertIn("watchdog", runner.ProgressReporter._label(result))

    def test_diagnostics_are_bounded_and_tolerate_malformed_observations(self):
        stderr = self.diagnostic_lines({"kind": []}, {"kind": "unknown"},
            {"kind": "subtest-complete", "completed": "oops"})
        stderr += "info: ZIBRA_WPT_DIAGNOSTIC {broken}\n"
        stderr += self.diagnostic_lines(*({"kind": "script-error", "error_kind": "ExceptionThrown", "detail": "error"} for _ in range(200)))
        diagnostic = runner.analyze_testharness("dom/a.html", "file:///a", stderr)
        self.assertEqual(4, diagnostic["malformed_events"])
        self.assertTrue(diagnostic["events_truncated"])
        self.assertEqual(8, len(diagnostic["script_errors"]))

    def test_late_script_error_survives_progress_budget_exhaustion(self):
        stderr = self.diagnostic_lines(*({"kind": "harness-started"} for _ in range(140)))
        stderr += self.diagnostic_lines({"kind": "script-error", "error_kind": "ExceptionThrown", "detail": "late failure"})
        diagnostic = runner.analyze_testharness("dom/a.html", "file:///a", stderr, {"status": "TIMEOUT"})
        self.assertEqual("script-error", diagnostic["reason"])
        self.assertTrue(diagnostic["events_truncated"])
        self.assertEqual("late failure", diagnostic["script_errors"][0]["detail"])

    def test_old_binary_diagnostics_do_not_claim_harness_start_or_cpu_stall(self):
        record = {"status": "TIMEOUT", "harness": None}
        diagnostic = runner.analyze_testharness("dom/test.any.worker.html", "http://localhost/dom/test.any.js", "", record)
        self.assertEqual("wrong-entry-url", diagnostic["reason"])
        self.assertEqual(["worker"], diagnostic["prerequisite_hints"])
        stderr = "error: Parser script setup.js (123 bytes) crashed: error.ParseError\ninfo: GET http://localhost/resources/testdriver.js\n"
        diagnostic = runner.analyze_testharness("dom/test.html", "file:///test", stderr, record)
        self.assertEqual("script-error", diagnostic["reason"])
        self.assertEqual("setup.js", diagnostic["script_errors"][0]["source"])
        self.assertEqual(["testdriver"], diagnostic["prerequisite_hints"])

    def test_local_fixture_capture_preserves_streams_and_enforces_watchdog(self):
        spec = importlib.util.spec_from_file_location("wpt_capture_fixture", Path(__file__).with_name("capture.py"))
        capture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(capture)
        for error, expected_exit in ((None, 0), ("watchdog expired", 1)):
            stdout, stderr = io.StringIO(), io.StringIO()
            with (
                mock.patch.object(sys, "argv", ["capture.py", "zibra", "--wpt-test", "file:///fixture", "--wpt-timeout-ms", "500"]),
                mock.patch.object(capture, "_invoke", return_value=runner.ProcessOutcome(
                    "result\u2028data\n", "diagnostics\n", infrastructure_error=error,
                )) as invoke,
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr),
            ):
                self.assertEqual(expected_exit, capture.main())
            invoke.assert_called_once_with(
                ["zibra", "--wpt-test", "file:///fixture", "--wpt-timeout-ms", "500"],
                0.5 + runner.WATCHDOG_GRACE_SECONDS,
            )
            self.assertEqual("result\u2028data\n", stdout.getvalue())
            self.assertIn("diagnostics", stderr.getvalue())

    def test_report_and_progress_summarize_timeout_causes_without_changing_counts(self):
        case = runner.Case("dom/example.html", "testharness", "fixture")
        results = [
            runner.CaseResult(case, "TIMEOUT", False, diagnostics={"reason": "script-error"}),
            runner.CaseResult(case, "INFRA", False, diagnostics={"reason": "watchdog-expired", "timeout_kind": "watchdog"}),
        ]
        output = io.StringIO()
        reporter = runner.ProgressReporter([case, case], "testharness", 1, output)
        for result in results:
            reporter.record(result)
        reporter.finish(True)
        self.assertIn("script-error=1", output.getvalue())
        self.assertIn("watchdog-expired=1", output.getvalue())
        report = self.root / "diagnostic-summary.json"
        now = runner.datetime.now(runner.timezone.utc)
        runner.write_run_report(report, manifest=Path("fixture.yaml"), mode="testharness",
            browser=["unused"], started_at=now, finished_at=now, results=results)
        summary = json.loads(report.read_text(encoding="utf-8"))["summary"]
        self.assertEqual(1, summary["timeout"])
        self.assertEqual(1, summary["infra"])
        self.assertEqual({"script-error": 1, "watchdog-expired": 1}, summary["timeout_diagnostics"])

    def test_browser_revision_strips_task_shell_artifacts(self):
        with mock.patch.dict(
            runner.os.environ,
            {"ZIBRA_GIT_SHA": "9476(git rev-parse --short HEAD 2>/dev/null || printf working-tree)"},
            clear=False,
        ):
            self.assertEqual("9476", runner._browser_revision())

    def write_manifest(self, **overrides):
        case = {
            "path": self.case_path,
            "mode": "testharness",
            "status": "candidate",
            "reason": "Focused runner fixture.",
            "timeout_ms": 20,
            "expectation": "pass",
        }
        case.update(overrides)
        manifest = self.root / "manifest.json"
        manifest.write_text(
            json.dumps({"version": 1, "tests": [case]}), encoding="utf-8"
        )
        return manifest

    def write_browser(self, source):
        browser = self.root / "fake_browser.py"
        browser.write_text(source, encoding="utf-8")
        return browser

    def run_main(
        self,
        manifest,
        browser,
        mode="testharness",
        grace_seconds=5.0,
        jobs=1,
        report=None,
        checkpoint_every=None,
        verbose=False,
        full_suite=False,
        directories=None,
    ):
        stdout = io.StringIO()
        stderr = io.StringIO()
        argv = [
            str(manifest),
            "--mode",
            mode,
            "--browser",
            sys.executable,
            str(browser),
            "--jobs",
            str(jobs),
        ]
        if report is not None:
            argv.extend(("--report", str(report)))
        if checkpoint_every is not None:
            argv.extend(("--checkpoint-every", str(checkpoint_every)))
        if verbose:
            argv.append("--verbose")
        if full_suite:
            argv.append("--full-suite")
        for directory in directories or []:
            argv.extend(("--directory", directory))
        with (
            mock.patch.object(runner, "ROOT", self.root),
            mock.patch.object(runner, "UPSTREAM", self.upstream),
            mock.patch.object(
                runner, "WATCHDOG_GRACE_SECONDS", grace_seconds
            ),
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            return runner.main(argv), stdout.getvalue(), stderr.getvalue()

    def test_discovery_uses_harness_marker_and_skips_support_files(self):
        harness = self.upstream / "dom" / "discovered.html"
        harness.write_text(
            '<script src="/resources/testharness.js"></script>', encoding="utf-8"
        )
        support = self.upstream / "resources" / "support.html"
        support.parent.mkdir()
        support.write_text(
            '<script src="/resources/testharness.js"></script>', encoding="utf-8"
        )
        manual = self.upstream / "dom" / "case-manual.html"
        manual.write_text(
            '<script src="/resources/testharness.js"></script>', encoding="utf-8"
        )

        with mock.patch.object(runner, "UPSTREAM", self.upstream):
            cases = runner.discover_testharness_cases()

        self.assertEqual(["dom/discovered.html"], [case.path for case in cases])
        self.assertEqual("testharness", cases[0].mode)

    def test_reftest_captures_test_and_reference_and_applies_relation(self):
        test = runner.Case(
            path="css/test.html",
            mode="reftest",
            reason="reftest fixture",
            references=(("/css/ref.html", "!="),),
        )

        def png(color):
            width, height = 2, 80
            raw = b"".join(b"\0" + color * width for _ in range(height))

            def chunk(name, data):
                checksum = zlib.crc32(name + data) & 0xFFFFFFFF
                return struct.pack(">I", len(data)) + name + data + struct.pack(">I", checksum)

            return (
                b"\x89PNG\r\n\x1a\n"
                + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw))
                + chunk(b"IEND", b"")
            )

        def capture(command, _watchdog):
            output = Path(command[command.index("--screenshot") + 1])
            color = bytes((255, 0, 0, 255)) if "ref.html" not in command[-1] else bytes((0, 255, 0, 255))
            output.write_bytes(png(color))
            return runner.ProcessOutcome(stdout="", stderr="")

        with mock.patch.object(runner, "_invoke", side_effect=capture) as invoke:
            result = runner._run_reftest(
                test, "file:///wpt/css/test.html", ["fake-browser"]
            )

        self.assertTrue(result.ok)
        self.assertEqual("PASS", result.status)
        self.assertEqual("!=", result.record["comparisons"][0]["relation"])
        self.assertEqual(2, invoke.call_count)

    def test_crashtest_requires_a_healthy_browser_completion(self):
        test = runner.Case(
            path="html/crashtests/loads.html",
            mode="crashtest",
            reason="crashtest fixture",
        )

        def healthy_browser(command, _watchdog):
            output = Path(command[command.index("--screenshot") + 1])
            output.write_bytes(b"PNG fixture")
            return runner.ProcessOutcome(stdout="", stderr="", returncode=0)

        with mock.patch.object(runner, "_invoke", side_effect=healthy_browser):
            result = runner._run_crashtest(
                test, "file:///wpt/html/crashtests/loads.html", ["fake-browser"]
            )

        self.assertTrue(result.ok)
        self.assertEqual("PASS", result.status)
        self.assertEqual("windowless-screenshot", result.record["completion"])

        with mock.patch.object(
            runner,
            "_invoke",
            return_value=runner.ProcessOutcome(
                stdout="", stderr="crashed", infrastructure_error="browser exited with status -11", returncode=-11
            ),
        ):
            result = runner._run_crashtest(
                test, "file:///wpt/html/crashtests/loads.html", ["fake-browser"]
            )

        self.assertFalse(result.ok)
        self.assertEqual("CRASH", result.status)

    def test_discovery_classifies_generated_and_unsupported_entries(self):
        generated = self.upstream / "dom" / "generated.any.js"
        generated.write_text("// META: global=window,dedicatedworker\n", encoding="utf-8")
        reftest = self.upstream / "css" / "reference.html"
        reftest.parent.mkdir()
        reftest.write_text(
            '<link rel="match" href="reference-ref.html">', encoding="utf-8"
        )
        crash = self.upstream / "html" / "crashtests" / "loads.html"
        crash.parent.mkdir(parents=True)
        crash.write_text("<!doctype html>", encoding="utf-8")
        manual = self.upstream / "html" / "example-manual.html"
        manual.parent.mkdir(parents=True, exist_ok=True)
        manual.write_text("<p>operator test</p>", encoding="utf-8")

        with mock.patch.object(runner, "UPSTREAM", self.upstream):
            inventory = runner.discover_wpt_inventory()

        self.assertEqual(
            [
                ("css/reference.html", "reftest", True),
                ("dom/generated.any.html", "testharness", True),
                ("dom/generated.any.worker.html", "testharness", True),
                ("html/crashtests/loads.html", "crashtest", True),
                ("html/example-manual.html", "manual", False),
            ],
            [(item.path, item.category, item.runnable) for item in inventory],
        )
        self.assertEqual(
            (("/css/reference-ref.html", "=="),),
            next(item.references for item in inventory if item.category == "reftest"),
        )
        summary = runner.inventory_summary(inventory)
        self.assertEqual(5, summary["total"])
        self.assertEqual(4, summary["runnable"])
        self.assertEqual(
            {"crashtest": 1, "reftest": 1, "testharness": 2},
            summary["runnable_by_category"],
        )
        self.assertEqual(
            {"crashtest": 1, "manual": 1, "reftest": 1, "testharness": 2},
            summary["categories"],
        )

    def test_discovery_prefers_wpt_manifest_and_keeps_generated_source_path(self):
        manifest = self.upstream / "MANIFEST.json"
        manifest.write_text(
            json.dumps(
                {
                    "version": 9,
                    "items": {
                        "testharness": {
                            "dom": {
                                "generated.any.js": [
                                    "hash",
                                    ["dom/generated.any.html", {}],
                                    ["dom/generated.any.worker.html", {}],
                                ]
                            }
                        },
                        "reftest": {
                            "css": {"case.html": ["hash", [None, {}]]}
                        },
                    },
                }
            ),
            encoding="utf-8",
        )

        with mock.patch.object(runner, "UPSTREAM", self.upstream):
            inventory = runner.discover_wpt_inventory()
            self.assertEqual("wpt-manifest", runner.inventory_summary(inventory)["source"])
        self.assertEqual(
            [
                ("css/case.html", "css/case.html", "reftest"),
                ("dom/generated.any.html", "dom/generated.any.js", "testharness"),
                ("dom/generated.any.worker.html", "dom/generated.any.js", "testharness"),
            ],
            [(item.path, item.source_path, item.category) for item in inventory],
        )

    def test_parallel_workers_keep_all_results_and_isolate_processes(self):
        second_path = "dom/second.html"
        (self.upstream / second_path).write_text(
            "<!doctype html>", encoding="utf-8"
        )
        manifest = self.root / "parallel.json"
        entries = [
            {
                "path": path,
                "mode": "testharness",
                "status": "candidate",
                "reason": "parallel fixture",
                "timeout_ms": 100,
                "expectation": "pass",
            }
            for path in (self.case_path, second_path)
        ]
        manifest.write_text(json.dumps({"version": 1, "tests": entries}), encoding="utf-8")
        browser = self.write_browser(
            """\
import json
import sys
print(json.dumps({
    "protocol_version": 1,
    "test": sys.argv[2],
    "status": "PASS",
    "duration_ms": 1,
}))
"""
        )
        report = self.root / "parallel-report.json"

        status, stdout, stderr = self.run_main(
            manifest, browser, jobs=2, report=report, checkpoint_every=1
        )

        self.assertEqual(0, status)
        self.assertIn("WPT testharness: 2 cases (2 workers)", stdout)
        self.assertIn("done dom/ 2/2", stdout)
        self.assertIn("WPT complete: 2/2 cases", stdout)
        self.assertEqual("", stderr)
        payload = json.loads(report.read_text(encoding="utf-8"))
        self.assertEqual(2, payload["summary"]["total"])
        self.assertEqual(2, payload["summary"]["pass"])

    def test_progress_records_each_folder_without_case_diagnostic_noise(self):
        second_path = "html/second.html"
        (self.upstream / second_path).parent.mkdir()
        (self.upstream / second_path).write_text(
            "<!doctype html>", encoding="utf-8"
        )
        manifest = self.root / "folders.json"
        entries = [
            {
                "path": path,
                "mode": "testharness",
                "status": "candidate",
                "reason": "folder progress fixture",
                "timeout_ms": 100,
                "expectation": "pass",
            }
            for path in (self.case_path, second_path)
        ]
        manifest.write_text(json.dumps({"version": 1, "tests": entries}), encoding="utf-8")
        browser = self.write_browser(
            """\
import json
import sys
print(json.dumps({
    "protocol_version": 1,
    "test": sys.argv[2],
    "status": "PASS",
    "duration_ms": 1,
}))
"""
        )

        status, stdout, stderr = self.run_main(manifest, browser)

        self.assertEqual(0, status)
        self.assertEqual(1, stdout.count("done dom/ 1/1"))
        self.assertEqual(1, stdout.count("done html/ 1/1"))
        self.assertIn("WPT complete: 2/2 cases — 2 pass", stdout)
        self.assertNotIn("--- browser stdout ---", stderr)
        self.assertNotIn("--- browser stderr ---", stderr)

    def test_all_mode_runs_discovered_cases_without_a_manifest(self):
        for name in ("first.html", "second.html"):
            path = self.upstream / "dom" / name
            path.write_text(
                '<script src="/resources/testharness.js"></script>',
                encoding="utf-8",
            )
        browser = self.write_browser(
            """\
import json
import sys
print(json.dumps({
    "protocol_version": 1,
    "test": sys.argv[2],
    "status": "PASS",
    "duration_ms": 1,
}))
"""
        )
        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            mock.patch.object(runner, "ROOT", self.root),
            mock.patch.object(runner, "UPSTREAM", self.upstream),
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            status = runner.main(
                [
                    "--all",
                    "--jobs",
                    "2",
                    "--checkpoint-every",
                    "0",
                    "--browser",
                    sys.executable,
                    str(browser),
                ]
            )

        self.assertEqual(0, status)
        self.assertIn("Discovered 2 WPT tests (2 runnable all cases", stdout.getvalue())
        self.assertIn("done dom/ 2/2", stdout.getvalue())
        self.assertIn("WPT complete: 2/2 cases", stdout.getvalue())
        self.assertEqual("", stderr.getvalue())

    def test_yaml_directory_allowlist_expands_harness_cases(self):
        for path in ("dom/one.html", "dom/two.html", "accelerometer/one.html"):
            test_file = self.upstream / path
            test_file.parent.mkdir(parents=True, exist_ok=True)
            test_file.write_text(
                '<script src="/resources/testharness.js"></script>',
                encoding="utf-8",
            )
        manifest = self.root / "directories.yaml"
        manifest.write_text(
            "directories:\n  - dom\n",
            encoding="utf-8",
        )

        with mock.patch.object(runner, "UPSTREAM", self.upstream):
            cases = runner.load_cases(manifest)

        self.assertEqual(["dom/one.html", "dom/two.html"], [case.path for case in cases])

    def mixed_allowlist(self):
        sources = {
            self.case_path: '<script src="/resources/testharness.js"></script>',
            "dom/visual.html": '<link rel="match" href="visual-ref.html">'
                '<meta name="fuzzy" content="maxDifference=0-2;totalPixels=0-10">',
            "dom/visual-ref.html": "<p>reference</p>",
            "dom/load-crash.html": "<p>crashtest</p>",
            "dom/example-manual.html": "<p>manual</p>",
            "html/outside.html": '<script src="/resources/testharness.js"></script>',
        }
        for name, source in sources.items():
            path = self.upstream / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source, encoding="utf-8")
        manifest = self.root / "mixed.yaml"
        manifest.write_text(
            "directories:\n  - dom\ntests:\n  - dom/example.html\n"
            "reftests:\n  - dom/visual.html\nprobes:\n  - dom/visual-ref.html\n",
            encoding="utf-8",
        )
        return manifest

    def test_directory_allowlist_includes_all_adapters_and_keeps_metadata(self):
        manifest = self.mixed_allowlist()
        with (
            mock.patch.object(runner, "UPSTREAM", self.upstream),
            mock.patch.object(runner, "discover_wpt_inventory", wraps=runner.discover_wpt_inventory) as discover,
        ):
            cases = runner.load_cases(manifest)

        discover.assert_called_once_with()
        self.assertEqual(
            [("testharness", self.case_path), ("reftest", "dom/visual.html"),
             ("probe", "dom/visual-ref.html"), ("crashtest", "dom/load-crash.html")],
            [(case.mode, case.path) for case in cases],
        )
        self.assertEqual((("/dom/visual-ref.html", "=="),), cases[1].references)
        self.assertEqual((2, 10), cases[1].fuzzy)

    def test_mixed_run_dispatches_all_adapters_and_excludes_probes(self):
        manifest = self.mixed_allowlist()
        report = self.root / "mixed-report.json"
        called = []

        def run(case, url, _browser):
            called.append((case.mode, url))
            # One failure must not prevent subsequent categories from running.
            passed = case.mode != "reftest"
            return runner.CaseResult(case, "PASS" if passed else "FAIL", passed)

        with (
            mock.patch.object(runner, "_run_testharness", side_effect=run),
            mock.patch.object(runner, "_run_reftest", side_effect=run),
            mock.patch.object(runner, "_run_crashtest", side_effect=run),
            mock.patch.object(runner, "_run_probe") as probe,
        ):
            status, stdout, stderr = self.run_main(manifest, "unused", mode="all", report=report)

        self.assertEqual(1, status)
        self.assertEqual("", stderr)
        self.assertEqual(list(runner.CONFORMANCE_MODES), [mode for mode, _url in called])
        probe.assert_not_called()
        self.assertIn("Categories: testharness=1, reftest=1, crashtest=1", stdout)
        payload = json.loads(report.read_text(encoding="utf-8"))
        self.assertEqual("all", payload["mode"])
        self.assertEqual(3, payload["expected_cases"])
        self.assertEqual(["PASS", "FAIL", "PASS"], [item["status"] for item in payload["tests"]])

    def test_category_filter_applies_to_listing_and_skipped_cases(self):
        manifest = self.mixed_allowlist()
        with manifest.open("a", encoding="utf-8") as stream:
            stream.write("deviations:\n  dom/load-crash.html: skip\n")
        stdout = io.StringIO()
        with mock.patch.object(runner, "UPSTREAM", self.upstream), contextlib.redirect_stdout(stdout):
            self.assertEqual(0, runner.main([str(manifest), "--list", "--mode", "reftest"]))
        self.assertIn("reftest", stdout.getvalue())
        self.assertNotIn("crashtest", stdout.getvalue())
        self.assertNotIn("testharness", stdout.getvalue())
        self.assertNotIn("probe", stdout.getvalue())
        with mock.patch.object(runner, "_run_reftest", side_effect=lambda case, *_: runner.CaseResult(case, "PASS", True)):
            status, stdout, stderr = self.run_main(manifest, "unused", mode="reftest")
        self.assertEqual(0, status)
        self.assertIn("WPT complete: 1/1 cases", stdout)
        self.assertNotIn("load-crash.html", stdout)
        self.assertEqual("", stderr)

    def test_full_suite_all_mode_counts_unselected_visual_and_crash_cases(self):
        self.mixed_allowlist()
        manifest = self.write_manifest()
        report = self.root / "mixed-coverage.json"
        with (
            mock.patch.object(runner, "_run_testharness", side_effect=lambda case, *_: runner.CaseResult(case, "PASS", True)),
            mock.patch.object(runner, "discover_wpt_inventory", wraps=runner.discover_wpt_inventory) as discover,
        ):
            status, _stdout, stderr = self.run_main(manifest, "unused", mode="all", full_suite=True, report=report)
        discover.assert_called_once_with()
        self.assertEqual(1, status)
        self.assertEqual("", stderr)
        payload = json.loads(report.read_text(encoding="utf-8"))
        self.assertEqual(4, payload["expected_cases"])
        self.assertEqual(3, payload["summary"]["skipped_cases"])
        scores = {item["path"]: item for item in payload["directory_scores"]}
        self.assertEqual({"path": "dom/", "passed": 1, "total": 3, "skipped": 2}, scores["dom/"])

    def test_coverage_identity_includes_category(self):
        harness = runner.Case(self.case_path, "testharness", "fixture")
        visual = runner.Case(self.case_path, "reftest", "fixture")
        self.assertEqual(
            [{"path": "dom/", "passed": 1, "total": 2, "skipped": 1}],
            runner._coverage_scores([harness, visual], [runner.CaseResult(harness, "PASS", True)]),
        )

    def test_served_generated_case_uses_variant_url_not_javascript_source(self):
        source = self.upstream / "dom/generated.any.js"
        source.write_text("// META: global=window\n// META: variant=?variant\n", encoding="utf-8")
        (self.upstream / "wpt").touch()
        manifest = self.root / "generated.yaml"
        manifest.write_text("directories:\n  - dom\n", encoding="utf-8")
        with (
            mock.patch.object(runner, "WptServer") as server,
            mock.patch.object(runner, "_run_testharness", side_effect=lambda case, *_: runner.CaseResult(case, "PASS", True)) as run,
        ):
            server.return_value.__enter__.return_value = "http://127.0.0.1:8000"
            status, _stdout, stderr = self.run_main(manifest, "unused", mode="all")
        self.assertEqual(0, status)
        self.assertEqual("", stderr)
        self.assertEqual("http://127.0.0.1:8000/dom/generated.any.html?variant", run.call_args.args[1])
        server.return_value.__exit__.assert_called_once_with(None, None, None)

    def test_full_suite_scores_unselected_directories_as_zero_and_fails(self):
        harness = self.upstream / self.case_path
        harness.write_text(
            '<script src="/resources/testharness.js"></script>',
            encoding="utf-8",
        )
        skipped = self.upstream / "accelerometer" / "one.html"
        skipped.parent.mkdir()
        skipped.write_text(
            '<script src="/resources/testharness.js"></script>',
            encoding="utf-8",
        )
        manifest = self.write_manifest()
        browser = self.write_browser(
            """\
import json
import sys
print(json.dumps({
    "protocol_version": 1,
    "test": sys.argv[2],
    "status": "PASS",
    "duration_ms": 1,
}))
"""
        )
        report = self.root / "coverage-report.json"

        status, stdout, stderr = self.run_main(
            manifest, browser, report=report, full_suite=True
        )

        self.assertEqual(1, status)
        self.assertEqual("", stderr)
        payload = json.loads(report.read_text(encoding="utf-8"))
        self.assertTrue(payload["summary"]["suite_failed"])
        self.assertEqual(1, payload["summary"]["skipped_cases"])
        scores = {item["path"]: item for item in payload["directory_scores"]}
        self.assertEqual(
            {"path": "accelerometer/", "passed": 0, "total": 1, "skipped": 1},
            scores["accelerometer/"],
        )

    def test_directory_filter_keeps_unselected_cases_out_of_execution(self):
        for path in ("dom/one.html", "html/one.html"):
            test_file = self.upstream / path
            test_file.parent.mkdir(parents=True, exist_ok=True)
            test_file.write_text("<html></html>", encoding="utf-8")
        manifest = self.root / "filter.json"
        manifest.write_text(
            json.dumps(
                {
                    "version": 1,
                    "tests": [
                        {
                            "path": "dom/one.html",
                            "mode": "testharness",
                            "status": "candidate",
                            "reason": "filter fixture",
                            "timeout_ms": 100,
                            "expectation": "pass",
                        },
                        {
                            "path": "html/one.html",
                            "mode": "testharness",
                            "status": "candidate",
                            "reason": "filter fixture",
                            "timeout_ms": 100,
                            "expectation": "pass",
                        },
                    ],
                }
            ),
            encoding="utf-8",
        )
        browser = self.write_browser(
            """\
import json
import sys
print(json.dumps({
    "protocol_version": 1,
    "test": sys.argv[2],
    "status": "PASS",
    "duration_ms": 1,
}))
"""
        )

        status, stdout, stderr = self.run_main(
            manifest, browser, directories=["dom"]
        )

        self.assertEqual(0, status)
        self.assertIn("WPT complete: 1/1 cases", stdout)
        self.assertNotIn("html/one.html", stdout)
        self.assertEqual("", stderr)

    def test_probe_stays_an_explicit_non_conformance_smoke_test(self):
        manifest = self.write_manifest(
            mode="probe", expectation=None, timeout_ms=100
        )
        browser = self.write_browser(
            """\
import sys
if len(sys.argv) != 3 or sys.argv[1] != "--dump-dom":
    raise SystemExit(9)
print("<html></html>")
"""
        )

        status, stdout, stderr = self.run_main(manifest, browser, mode="probe")

        self.assertEqual(0, status)
        self.assertIn("WPT probe: 1 cases", stdout)
        self.assertIn("done dom/ 1/1 — 1 probe", stdout)
        self.assertEqual("", stderr)

    def test_yaml_allowlist_uses_conventional_sections_and_deviations(self):
        manifest = self.root / "manifest.yaml"
        manifest.write_text(
            """\
tests:
  - dom/example.html
crashtests:
  - html/crashtests/loads.html
probes:
  - html/probe.html
deviations:
  dom/example.html: fail
""",
            encoding="utf-8",
        )

        cases = runner.load_cases(manifest)

        self.assertEqual(
            [
                ("dom/example.html", "testharness", "fail"),
                ("html/crashtests/loads.html", "crashtest", None),
                ("html/probe.html", "probe", None),
            ],
            [(case.path, case.mode, case.expectation) for case in cases],
        )

    def test_testharness_invocation_accepts_an_exact_expected_timeout(self):
        manifest = self.write_manifest(expectation="timeout", timeout_ms=17)
        browser = self.write_browser(
            """\
import json
import sys
if sys.argv[1] != "--wpt-test":
    raise SystemExit(9)
if sys.argv[3:] != ["--wpt-timeout-ms", "17"]:
    raise SystemExit(10)
print(json.dumps({
    "protocol_version": 1,
    "test": sys.argv[2],
    "status": "TIMEOUT",
    "duration_ms": 17,
}))
"""
        )

        status, stdout, stderr = self.run_main(manifest, browser)

        self.assertEqual(0, status)
        self.assertIn(f"TIMEOUT {self.case_path}", stdout)
        self.assertEqual("", stderr)

    def test_expectation_mismatch_preserves_raw_stdout_and_stderr(self):
        manifest = self.write_manifest(expectation="pass")
        browser = self.write_browser(
            """\
import json
import sys
print(json.dumps({
    "protocol_version": 1,
    "test": sys.argv[2],
    "status": "FAIL",
    "duration_ms": 4,
}))
print("assertion detail", file=sys.stderr)
"""
        )

        status, stdout, stderr = self.run_main(manifest, browser, verbose=True)

        self.assertEqual(1, status)
        self.assertIn("FAIL (expected PASS)", stdout)
        self.assertIn('"status": "FAIL"', stderr)
        self.assertIn("assertion detail", stderr)
        self.assertIn("--- browser stdout ---", stderr)
        self.assertIn("--- browser stderr ---", stderr)

    def test_nonzero_exit_is_infrastructure_even_with_valid_json(self):
        manifest = self.write_manifest(expectation="fail")
        browser = self.write_browser(
            """\
import json
import sys
print(json.dumps({
    "protocol_version": 1,
    "test": sys.argv[2],
    "status": "FAIL",
    "duration_ms": 1,
}))
print("crash detail", file=sys.stderr)
raise SystemExit(7)
"""
        )

        status, stdout, stderr = self.run_main(manifest, browser, verbose=True)

        self.assertEqual(1, status)
        self.assertIn("INFRA", stdout)
        self.assertIn("browser exited with status 7", stderr)
        self.assertIn('"status": "FAIL"', stderr)
        self.assertIn("crash detail", stderr)

    def test_malformed_json_is_infrastructure_and_preserves_output(self):
        manifest = self.write_manifest()
        browser = self.write_browser(
            """\
import sys
print("not JSON")
print("parse detail", file=sys.stderr)
"""
        )

        status, stdout, stderr = self.run_main(manifest, browser, verbose=True)

        self.assertEqual(1, status)
        self.assertIn("INFRA", stdout)
        self.assertIn("invalid JSON result", stderr)
        self.assertIn("not JSON", stderr)
        self.assertIn("parse detail", stderr)

    def test_multiple_json_lines_are_infrastructure(self):
        url = (self.upstream / self.case_path).resolve().as_uri()
        line = json.dumps(
            {
                "protocol_version": 1,
                "test": url,
                "status": "PASS",
                "duration_ms": 1,
            }
        )

        with self.assertRaisesRegex(ValueError, "exactly one JSON result line"):
            runner.parse_testharness_result(f"{line}\n{line}\n", url)

    def test_protocol_version_must_be_exact_integer_one(self):
        url = (self.upstream / self.case_path).resolve().as_uri()
        for version in (None, True, 2, "1"):
            with self.subTest(version=version):
                line = json.dumps(
                    {
                        "protocol_version": version,
                        "test": url,
                        "status": "PASS",
                        "duration_ms": 1,
                    }
                )
                with self.assertRaisesRegex(ValueError, "protocol_version"):
                    runner.parse_testharness_result(line, url)

    def test_process_watchdog_expiry_is_not_a_semantic_timeout(self):
        manifest = self.write_manifest(expectation="timeout", timeout_ms=1)
        browser = self.write_browser("while True:\n    pass\n")

        status, stdout, stderr = self.run_main(
            manifest, browser, grace_seconds=0.0, verbose=True
        )

        self.assertEqual(1, status)
        self.assertIn("INFRA", stdout)
        self.assertIn("browser watchdog expired", stderr)
        self.assertNotIn(f"ok {self.case_path}: TIMEOUT", stdout)
        self.assertIn("--- browser stdout ---", stderr)

    def test_report_writes_summary_and_subtest_details(self):
        manifest = self.write_manifest()
        browser = self.write_browser(
            """\
import json
import sys
print(json.dumps({
    "protocol_version": 1,
    "test": sys.argv[2],
    "status": "PASS",
    "duration_ms": 7,
    "tests": [{"name": "lookup", "status": "PASS", "code": 0}],
    "harness": {"status": "OK", "code": 0},
}))
"""
        )
        report = self.root / "results" / "run.json"

        # The test helper does not pass --report by default; exercise the
        # public entry point directly for the durable artifact option.
        with (
            mock.patch.object(runner, "ROOT", self.root),
            mock.patch.object(runner, "UPSTREAM", self.upstream),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            status = runner.main(
                [
                    str(manifest),
                    "--mode",
                    "testharness",
                    "--browser",
                    sys.executable,
                    str(browser),
                    "--report",
                    str(report),
                ]
            )

        self.assertEqual(0, status)
        payload = json.loads(report.read_text(encoding="utf-8"))
        self.assertEqual(1, payload["schema_version"])
        self.assertTrue(payload["complete"])
        self.assertEqual(1, payload["expected_cases"])
        self.assertEqual(1, payload["summary"]["pass"])
        self.assertEqual(1, payload["summary"]["subtests_total"])
        self.assertEqual(1, payload["summary"]["subtests_pass"])
        self.assertEqual("PASS", payload["tests"][0]["status"])
        self.assertEqual("lookup", payload["tests"][0]["tests"][0]["name"])


if __name__ == "__main__":
    unittest.main()
