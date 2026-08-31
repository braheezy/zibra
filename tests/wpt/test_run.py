import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


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

    def run_main(self, manifest, browser, mode="testharness", grace_seconds=5.0):
        stdout = io.StringIO()
        stderr = io.StringIO()
        argv = [
            str(manifest),
            "--mode",
            mode,
            "--browser",
            sys.executable,
            str(browser),
        ]
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
        self.assertIn("probe ok (non-conformance)", stdout)
        self.assertEqual("", stderr)

    def test_yaml_allowlist_uses_conventional_sections_and_deviations(self):
        manifest = self.root / "manifest.yaml"
        manifest.write_text(
            """\
tests:
  - dom/example.html
probes:
  - html/probe.html
deviations:
  dom/example.html: fail
""",
            encoding="utf-8",
        )

        cases = runner.load_cases(manifest)

        self.assertEqual(
            [("dom/example.html", "testharness", "fail"), ("html/probe.html", "probe", None)],
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
        self.assertIn(f"ok {self.case_path}: TIMEOUT", stdout)
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

        status, stdout, stderr = self.run_main(manifest, browser)

        self.assertEqual(1, status)
        self.assertIn("expected PASS, received FAIL", stdout)
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

        status, stdout, stderr = self.run_main(manifest, browser)

        self.assertEqual(1, status)
        self.assertIn("INFRA", stdout)
        self.assertIn("browser exited with status 7", stdout)
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

        status, stdout, stderr = self.run_main(manifest, browser)

        self.assertEqual(1, status)
        self.assertIn("INFRA", stdout)
        self.assertIn("invalid JSON result", stdout)
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
            manifest, browser, grace_seconds=0.0
        )

        self.assertEqual(1, status)
        self.assertIn("INFRA", stdout)
        self.assertIn("browser watchdog expired", stdout)
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
        with mock.patch.object(runner, "ROOT", self.root), mock.patch.object(
            runner, "UPSTREAM", self.upstream
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
        self.assertEqual(1, payload["summary"]["pass"])
        self.assertEqual(1, payload["summary"]["subtests_total"])
        self.assertEqual(1, payload["summary"]["subtests_pass"])
        self.assertEqual("PASS", payload["tests"][0]["status"])
        self.assertEqual("lookup", payload["tests"][0]["tests"][0]["name"])


if __name__ == "__main__":
    unittest.main()
