# Web Platform Tests

This directory is the integration point for a pinned Web Platform Tests
(WPT) checkout. The checkout is deliberately not committed here: run the
setup command below when you want to work on WPT compatibility.

```sh
git submodule add --depth 1 https://github.com/web-platform-tests/wpt.git tests/wpt/upstream
git submodule update --init --depth 1 tests/wpt/upstream
```

Install WPT's runner dependencies using the upstream instructions, then use
the helper from the repository root:

```sh
python3 tests/wpt/run.py --list
python3 tests/wpt/run.py --mode probe tests/wpt/manifest.json
python3 tests/wpt/run.py --mode testharness tests/wpt/manifest.json
zig build test-wpt-runner
zig build test-wpt
```

`probe` is intentionally a fetch/parse smoke test. Zibra's `--dump-dom`
inspection mode does not construct a `Browser` or execute JavaScript, so it
cannot report `testharness.js` results. Its output is labeled
`non-conformance`; never interpret a successful probe as a WPT pass.

`testharness` runs each selected file in a real headless browser session. When
the upstream checkout is initialized, the runner starts WPT's `wptserve` on a
temporary loopback port so root-relative resources such as
`/resources/testharness.js` resolve exactly as they do in WPT. A
manifest entry may add a positive `timeout_ms` (10,000 by default) and an
`expectation` of `pass`, `fail`, `error`, `timeout`, or `skip`. Expectations
are exact: an expected `fail` does not accept `ERROR` or `TIMEOUT`. Without an
expectation, the runner expects `PASS`. The existing `status: "skip"` form is
also supported. The reviewed manifest contains the legacy `probe` and one
upstream DOM smoke test; add further cases only after their dependencies are
verified.

For each case the runner invokes:

```text
zibra --wpt-test <absolute-file-url> --wpt-timeout-ms <n>
```

Zibra must exit successfully and write exactly one JSON result line to stdout.
The object must contain integer `protocol_version: 1`, the requested URL as
`test`, one of `PASS`, `FAIL`, `ERROR`, or `TIMEOUT` as `status`, and a
non-negative integer `duration_ms`. Diagnostics belong on stderr. A JSON
`TIMEOUT` is a semantic test result; a runner watchdog expiry, nonzero browser
exit, malformed result, or extra stdout line is an infrastructure failure.
Failed cases reproduce the browser's raw stdout and stderr in the runner
diagnostics.

The two build steps need neither the upstream checkout nor network access.
`test-wpt-runner` exercises manifest selection and process/result failure
classification with fake browsers; `test-wpt` runs local headless synchronous
PASS, Promise-job PASS, and TIMEOUT fixtures through the real executable and
validates its JSON transport. Those local fixtures are protocol regressions,
not WPT conformance claims.

The manifest is the compatibility allowlist. It includes one upstream DOM
smoke test as a starting point. Add tests only with a short reason and an
explicit mode; keep unsupported tests recorded as `skip` rather than silently
broadening the run.
