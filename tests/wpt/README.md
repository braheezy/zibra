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
python3 tests/wpt/run.py --mode probe tests/wpt/manifest.yaml
python3 tests/wpt/run.py --mode testharness tests/wpt/manifest.yaml
task wpt
python3 tests/wpt/run.py --all --jobs 4 --mode testharness \
  --browser ./zig-out/bin/zibra \
  --report tests/wpt/results/all.json
zig build test-wpt-runner
zig build test-wpt
docker compose -f tests/wpt/dashboard/docker-compose.yml up --build
```

`probe` is intentionally a fetch/parse smoke test. Zibra's `--dump-dom`
inspection mode does not construct a `Browser` or execute JavaScript, so it
cannot report `testharness.js` results. Its output is labeled
`non-conformance`; never interpret a successful probe as a WPT pass.

`testharness` runs each selected file in a real headless browser session. When
the upstream checkout is initialized, the runner starts WPT's `wptserve` on a
temporary loopback port so root-relative resources such as
`/resources/testharness.js` resolve exactly as they do in WPT. The YAML
allowlist expands testharness directories from `directories`, accepts
individual cases under `tests`, and puts fetch/parse smoke tests under
`probes`; all default to `PASS`. Add a path to the optional
`deviations` map only when its expected result differs (`fail`, `error`,
`timeout`, or `skip`). Timeouts use the 10,000 ms default.

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
Normal output is intentionally compact: it shows bounded progress and leaves a
durable `done <folder>/ ...` line when each top-level WPT folder finishes. Raw
browser output is retained in the JSON report for failed cases; pass
`--verbose` when interactively diagnosing a failure to echo that output to
stderr.

The two build steps need neither the upstream checkout nor network access.
`test-wpt-runner` exercises manifest selection and process/result failure
classification with fake browsers; `test-wpt` runs local headless synchronous
PASS, Promise-job PASS, and TIMEOUT fixtures through the real executable and
validates its JSON transport. Those local fixtures are protocol regressions,
not WPT conformance claims.

The YAML file is the compatibility allowlist. Add supported directory prefixes
to `directories`, individual cases to `tests`, and fetch/parse smoke tests to
`probes`; keep unsupported areas out of execution and record only intentional
expected deviations.

## Full local runs

`directories` entries in the reviewed YAML manifest expand to all discovered
testharness entries below those WPT directories, including generated variants.
`task wpt` runs that
allowlist with `--full-suite`: directories outside the allowlist are not
executed, but remain in the report as `0/N` and make the suite fail. This keeps
unsupported areas such as `accelerometer` visible without spending time on
them.

`--directory DIR` (repeatable) provides the same narrowing for ad-hoc runs.
`--all` discovers the WPT test inventory, preferring WPT's generated
`MANIFEST.json` when present and otherwise applying the same source naming and
metadata rules locally. This includes generated `.any.js`, `.window.js`, and
`.worker.js` variants. The report classifies testharness, reftest, manual,
visual, WebDriver, crash, accessibility, conformance-checker, and Test262
entries separately. Only testharness entries are currently runnable by
Zibra's JSON protocol; the others increase the honest discovered total but
remain unsupported and are not executed. Support files are not counted as
tests. A full inventory run therefore reports both the total discovered WPT
tests and its smaller runnable testharness subset.

Build Zibra once, then run several independent browser processes against one
temporary WPT server:

```sh
zig build
mkdir -p tests/wpt/results
python3 tests/wpt/run.py --all --mode testharness --jobs 4 \
  --browser ./zig-out/bin/zibra \
  --report tests/wpt/results/all-$(date -u +%Y%m%dT%H%M%SZ).json
```

`--jobs` defaults to one to preserve focused-run behavior; increase it to
match available CPU and memory. Every case has its own watchdog. A crash,
malformed result, non-zero exit, or watchdog expiry is recorded as `INFRA` and
does not abort the remaining cases. Watchdog cleanup kills the whole browser
process group, preventing a stuck page from leaking children into later
runs. The runner prints one live progress line on a terminal (or roughly one
checkpoint per percent when redirected), followed by a per-folder summary and
an overall total. Reports are atomically checkpointed every 25 completed cases
by default;
use `--checkpoint-every 0` to disable checkpoints. A checkpoint is still a
valid dashboard report and is replaced by the complete report at the end.

The Taskfile provides the same workflow and uses four workers by default:

```sh
task wpt-all
WPT_JOBS=8 task wpt-all
```

Use `task wpt` for the reviewed compatibility suite and `task wpt-all` only
when deliberately auditing the complete discovered testharness corpus.

For a local visual history, write a report while running the manifest and
start the self-hosted dashboard:

```sh
mkdir -p tests/wpt/results
python3 tests/wpt/run.py tests/wpt/manifest.yaml \
  --mode testharness --browser ./zig-out/bin/zibra \
  --report tests/wpt/results/$(date -u +%Y%m%dT%H%M%SZ).json
docker compose -f tests/wpt/dashboard/docker-compose.yml up --build
```

See [`dashboard/README.md`](dashboard/README.md) for the read-only API and
GitHub Pages deployment shape.

From the repository root, the shorter equivalents are:

```sh
task latest-results
task dom-results
task dashboard
```

`latest-results` keeps each run as a timestamped JSON file under
`tests/wpt/results`; `dashboard` serves that history at
<http://localhost:8188>.

`dom-results` uses the focused `manifest-dom.yaml` allowlist for DOM mutation,
traversal, and Range work. It stays separate from the default manifest so
higher-signal checks can evolve without making every fast run depend on the
entire DOM compatibility surface.

`task acid3-results` runs the upstream `acid/acid3/numbered-tests.html`
harness. Its single page contains 100 numbered subtests; reports retain each
failure and the dashboard uses the subtest counts for the Acid3 score and
history chart. Acid3 includes a deliberately expensive stress test, so this
task uses a 120-second timeout; use `--timeout-ms` for a different bounded
window when invoking `run.py` directly.

The runner records `ZIBRA_GIT_SHA` in each report. The Taskfile fills it from
the current checkout automatically (or uses `working-tree` when no Git
revision is available), and the dashboard displays it as the browser column.
