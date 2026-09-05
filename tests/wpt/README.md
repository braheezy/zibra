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
task wpt-smoke
python3 tests/wpt/run.py --all --jobs 4 --mode all \
  --browser ./zig-out/bin/zibra \
  --report tests/wpt/results/all.json
python3 tests/wpt/run.py --all --mode reftest --jobs 4 \
  --browser ./zig-out/bin/zibra \
  --report tests/wpt/results/reftest.json
python3 tests/wpt/run.py --all --mode crashtest --jobs 4 \
  --browser ./zig-out/bin/zibra \
  --report tests/wpt/results/crashtest.json
zig build test-wpt-runner
zig build test-wpt
docker compose -f tests/wpt/dashboard/docker-compose.yml up --build
```

`probe` is intentionally a fetch/parse smoke test. Zibra's `--dump-dom`
inspection mode does not construct a `Browser` or execute JavaScript, so it
cannot report `testharness.js` results. Its output is labeled
`non-conformance`; never interpret a successful probe as a WPT pass.

`all` is the default mode: it dispatches allowlisted testharness, reftest, and
crashtest cases to their respective adapters. It excludes non-conformance
probes; use `--mode probe` explicitly for those. A category-specific `--mode`
filters both execution and `--list` output.

`testharness` runs each selected file in a real headless browser session. When
the upstream checkout is initialized, the runner starts WPT's `wptserve` on a
temporary loopback port so root-relative resources such as
`/resources/testharness.js` resolve exactly as they do in WPT. The YAML
allowlist expands all three runnable categories from `directories`, accepts
individual cases under `tests`, `reftests`, and `crashtests`, and puts
fetch/parse smoke tests under `probes`. Conformance cases default to `PASS`.
Add a path to the optional
`deviations` map only when its expected result differs (`fail`, `error`,
`timeout`, or `skip`). Timeouts use the 10,000 ms default.

For each case the runner invokes:

```text
zibra --wpt-test <absolute-url> --wpt-timeout-ms <n>
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

### Diagnosing timeouts

Reports keep the terminal result separate from its diagnosis. JSONL framing
splits only at LF (CRLF is accepted); Unicode separators inside assertion
messages are data, not additional result records.

New browsers emit bounded `ZIBRA_WPT_DIAGNOSTIC` JSON events on stderr, enabled
only for WPT sessions. These record session/runtime/harness startup, a sample
of completed subtests, and uncaught outer-script/callback errors with source
labels and VM error text/stack when available. The budget is 32 KiB per Realm,
including 8 KiB reserved for errors after progress logging fills up. Individual
events are limited to 8 KiB. A truncation marker makes missing observations
explicit. No DOM pointers, JavaScript values, or source slices are retained by
the diagnostic log.

The runner adds `diagnostics` to each testharness case and
`summary.timeout_diagnostics` to the report, and prints a compact reason tally:

| Reason | What was observed |
| --- | --- |
| `watchdog-expired` | The outer process watchdog killed the browser; still `INFRA` |
| `harness-timeout` | The harness delivered a completed timeout result |
| `script-error` | A session deadline with a logged parse or uncaught script error |
| `execution-interrupted` | Script execution was interrupted at shutdown/deadline |
| `runtime-not-observed` | Session started but no runtime-ready event arrived |
| `harness-not-observed` | Runtime started but no harness-ready event arrived |
| `completion-pending` | Harness was observed but did not deliver a terminal result |
| `wrong-entry-url` | A timed-out invocation loaded a raw `.js` entry URL |
| `unknown` | Available evidence cannot identify the timeout reason |

These are observations, not proof of CPU usage or a deadlock. Sparse progress
counts are lower bounds, and partial subtests are diagnostic samples, not
conformance-score additions. Script errors do not override a valid harness
completion or turn a caught exception into a failure. Earlier binaries get
conservative diagnoses from existing parser-error logs. Testdriver, worker,
and SVG prerequisite hints do not automatically skip cases: use reviewed
allowlist entries and explicit `skip` deviations for known unsupported tests.
Promise rejection tracking, errors contained inside runtime event listeners,
child-context aggregation, and structured network-failure reporting remain
separate gaps; an empty error list is not proof that no error occurred.

The two build steps need neither the upstream checkout nor network access.
`test-wpt-runner` exercises manifest selection and process/result failure
classification with fake browsers; `test-wpt` runs local headless synchronous
PASS, Promise-job PASS, and TIMEOUT fixtures through the real executable and
validates its JSON transport. It also exercises partial progress, uncaught and
parse errors, caught exceptions, and Unicode framing. Captures run serially
under the same process-group watchdog as upstream cases. Those local fixtures are protocol regressions,
not WPT conformance claims.

The YAML file is the compatibility allowlist. Add supported directory prefixes
to `directories`, individual semantic cases to `tests`, individual visual
cases to `reftests`, crash cases to `crashtests`, and fetch/parse smoke tests to
`probes`; keep unsupported
areas out of execution and record only intentional expected deviations.

## Small real-browser smoke run

`task wpt-smoke` builds once and runs [manifest-smoke.yaml](manifest-smoke.yaml)
serially against the unchanged upstream checkout. It saves a timestamped report
and exercises all three adapters with these cases:

- `dom/nodes/Element-firstElementChild.html`: testharness assertions.
- `css/CSS2/backgrounds/background-color-174.xht`: a transparent child over a
  green background must match the reference's green image, pixel for pixel.
- `css/css-flexbox/flex-shrink-large-value-crash.html`: static flex layout with
  a very large shrink factor must reach screenshot completion and exit cleanly.

All three passed with the real Zibra executable on macOS; the reftest had zero
differing pixels. As a negative control, comparing that same test to the
unrelated `css/CSS2/reference/no-red-on-blank-page-ref.xht` fails. The two
static cases need neither testdriver nor asynchronous completion automation.
This proves the adapters can produce real results, not general WPT support.

## Full local runs

`directories` entries in the reviewed YAML manifest expand to all discovered
testharness, reftest, and crashtest entries below those WPT directories,
including generated variants and reference metadata. Explicit entries and
directory matches are deduplicated by category and test URL.
`task wpt` runs that mixed-category
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
entries separately. Testharness, reftest, and markup crashtest entries are
runnable together with `--mode all` or individually in their respective modes;
manual, visual, WebDriver, accessibility,
conformance-checker, and Test262 entries remain discovery-only. Test262 is
intentionally out of scope for this runner and belongs to Kiesel's JavaScript
compatibility work. Support files are not counted as tests. A full inventory
run therefore reports the total discovered WPT tests and the runnable count by
category.

Reftests use a visual adapter, included in mixed allowlist runs. To select only
reftests, use `--mode reftest`; `--all --mode reftest` or `task wpt-reftest`
deliberately selects the entire upstream reftest corpus. Each test page and its
WPT `match`/`mismatch`
references are captured through Zibra's windowless `--screenshot` mode. The
runner compares RGB/RGBA PNG page pixels after the stable 70-pixel chrome
strip, applies basic WPT fuzzy limits when present, and records per-reference
diagnostics. Missing references, screenshot failures, malformed PNGs, and
dimension mismatches are `INFRA`; a `mismatch` relation passes when the images
are different. This provides the harness boundary without claiming rendering
parity with the upstream browser.

Crashtests use a process-health adapter, also included in mixed allowlist runs.
`--mode crashtest` selects just that category; `--all --mode crashtest` or
`task wpt-crashtest` selects the entire upstream crashtest corpus.
Each case is loaded through Zibra's
windowless screenshot lifecycle, which waits for a complete/quiescent document
and requires a successful browser exit plus a captured frame. A healthy load is
`PASS`; a browser process crash is `CRASH`; a completion watchdog expiry is
`TIMEOUT`; launch and output problems are `INFRA`. This is intentionally an
early boundary: WPT's optional `class=test-wait` testdriver completion bridge
is not implemented yet, so tests requiring that automation remain unsupported.

Build Zibra once, then run several independent browser processes against one
temporary WPT server:

```sh
zig build
mkdir -p tests/wpt/results
python3 tests/wpt/run.py --all --mode all --jobs 4 \
  --browser ./zig-out/bin/zibra \
  --report tests/wpt/results/all-$(date -u +%Y%m%dT%H%M%SZ).json
```

`--jobs` defaults to one to preserve focused-run behavior; increase it to
match available CPU and memory. Each browser invocation has its own watchdog.
Infrastructure failures do not abort the remaining cases; crashtests retain
their distinct `CRASH` and `TIMEOUT` statuses. Watchdog cleanup kills the whole browser
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
when deliberately auditing the complete discovered runnable corpus across all
three categories. `--full-suite` coverage uses the selected categories too:
an omitted reftest or crashtest contributes zero just like an omitted
testharness case.

For a local visual history, write a report while running the manifest and
start the self-hosted dashboard:

```sh
mkdir -p tests/wpt/results
python3 tests/wpt/run.py tests/wpt/manifest.yaml \
  --mode all --browser ./zig-out/bin/zibra \
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
