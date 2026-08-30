# Web Platform Tests integration plan

This document describes how to turn the existing WPT scaffold into a useful
development and conformance system for Zibra. It is intentionally staged: WPT
is much larger than the browser's current API surface, and running tests before
the browser can report their completion produces misleading results.

## Current state

The WPT adapter vertical slice is implemented; executing the first unmodified
upstream test is the next milestone. The current implementation includes:

- `.gitmodules` registers the WPT checkout at `tests/wpt/upstream`;
  contributors initialize it only when doing upstream compatibility work. The
  runner/result protocol does not yet expose the resolved WPT revision.
  `manifest.json` remains the reviewed compatibility allowlist and currently
  contains only the legacy `probe`.
- `run.py` preserves `probe` as an explicitly labeled non-conformance fetch and
  parse smoke test. Its `testharness` mode invokes the WPT CLI protocol, checks
  exact expectations, and treats malformed output, crashes, and its outer
  watchdog as infrastructure failures.
- `src/browser/wpt_session.zig` owns one standalone headless Browser, drives
  `Browser.tick`, copies the first explicit report, accepts it after the Tab's
  serialized task-return barrier, gives the monotonic deadline precedence over
  an undrained report, and performs normal Browser teardown.
- `Browser` exposes a generic top-level-Realm observer. The WPT Session uses
  that seam to install its bridge after `Js.setNodes` creates the document
  Realm and before the first parser script, without adding WPT protocol logic
  to the Browser coordinator.
- `src/script/wpt_bindings.zig` exposes a generation-scoped serialized-result
  sink. The runtime supplies `self`, correct top-level `parent` identity, and a
  `completion_callback` compatible with the testharness external completion
  hook only when a WPT sink is installed. Outer Browser-to-JavaScript turns
  drain Kiesel Promise jobs to a fixed point before releasing `JsLock` and the
  active WindowRealm.
- `zibra --wpt-test <absolute-url> --wpt-timeout-ms <n>` writes exactly one
  protocol-v1 JSONL result to stdout after teardown. Diagnostics stay on
  stderr. `PASS`, `FAIL`, `ERROR`, and semantic `TIMEOUT` all produce a valid
  result record; a crash, nonzero exit, malformed record, or outer watchdog is
  an infrastructure failure.
- `zig build test-wpt` runs synchronous PASS, Promise-job PASS, and semantic
  TIMEOUT pages through the real executable. `zig build test-wpt-runner`
  covers manifest selection, exact expectations, malformed output, nonzero
  exits, protocol validation, and watchdog classification with fake browsers.

The committed coverage proves the adapter, process protocol, Promise checkpoint,
deadline race, and runner failure classification. It does not yet prove that
Zibra can execute an unmodified upstream `testharness.js` test. The runner
currently constructs file URLs, so an upstream reference such as
`/resources/testharness.js` cannot resolve correctly. `wptserve` and its origin
model are not orchestrated, and resource quiescence, cross-Realm Promise-job
routing, structured navigation/script failures, rejected-promise reporting,
console/network diagnostics, reftests, persistent sessions, and CI artifact
publishing remain incomplete.

`--dump-dom` still deliberately fetches and parses without constructing a
Browser, SDL, layout, or JavaScript. A successful probe is never a
`testharness.js` pass.

### Phase status snapshot

| Phase | Status | Current boundary |
| --- | --- | --- |
| 0. Pinning and schema | Partial | Submodule registration and allowlist exist; revision fields and persisted results do not |
| 1. Headless session | Core implemented | One URL, one Tab, explicit report/deadline, JSONL, and normal teardown work; viewport/UA configuration and structured load errors do not |
| 2. Harness reporting | Partial | Completion, subtests, Promise jobs, status mapping, and runner expectations work; upstream proof and full diagnostics do not |
| 3. Scheduling/cancellation | Partial | Task-return barrier, deadline arbitration, and JS interruption work; resource quiescence and complete transport cancellation do not |
| 4. Web APIs | Ongoing | Grow coherent slices from selected failures rather than attempting the full platform |
| 5. `wptserve` | Next milestone | Required before unchanged upstream resource URLs, headers, and origins can work |
| 6. Selection/expectations | Runner ready | Schema and comparison exist, but the allowlist has no `testharness` entry yet |
| 7. Reftests | Not started | Keep separate from semantic harness results |
| 8. Performance/CI | Partial | Local build checks exist; persistence, sharding, artifacts, and a persistent process do not |

## Next milestone: one unmodified upstream test

Zibra can accurately claim that it runs WPT after one existing upstream
`testharness.js` test passes unchanged through the reviewed manifest and the
current result protocol. Reach that milestone in this order:

1. Initialize the already-registered submodule and record the resolved WPT
   revision in the manifest and result metadata.
2. Add `wptserve` lifecycle ownership to `run.py`: deterministic configuration,
   worker-local ports, URL mapping from manifest paths, readiness detection,
   and unconditional shutdown in a `finally` path.
3. Select one small synchronous upstream test whose DOM/event dependencies are
   already implemented. Add it to the allowlist with type, timeout, explicit
   expectation, reason, and revision; do not modify the upstream file.
4. Prove that its unchanged `/resources/testharness.js` and
   `/resources/testharnessreport.js` requests load through `wptserve` and reach
   Zibra's existing completion bridge.
5. Preserve the protocol-v1 record, stderr, and server diagnostics for the run,
   and keep outer watchdog failures classified as infrastructure rather than
   semantic `TIMEOUT`.

After that first test, add structured navigation/script exception and
unhandled-rejection observers, persist per-test records and a run summary, and
grow one small DOM/events/timers shard with a focused Zibra regression for each
discovered failure.

## Design goals

1. Run one test in a real browsing context with the same parser, resource,
   JavaScript, lifecycle, and rendering paths used interactively.
2. Make completion, failure, timeout, and shutdown explicit and machine
   readable.
3. Keep document generations and asynchronous work safe under cancellation.
4. Separate semantic `testharness.js` tests, visual reftests, crash tests, and
   manual tests; they need different adapters and evidence.
5. Keep the committed compatibility claim reviewable: pin WPT, commit the
   selected manifest and expectations, and publish generated reports as CI
   artifacts.

## Target architecture

Add a dedicated WPT adapter layer rather than putting WPT conditionals into
the existing browser coordinator:

```text
tests/wpt/run.py
  -> WPT server + manifest selection
  -> one persistent Zibra process (eventually)
  -> test session / test result protocol
  -> Browser -> Tab -> Frame/Js/Loader
  -> JSON result stream
```

The first useful protocol can be process based: one invocation receives one
URL and writes one JSON result. Later, a persistent process can host several
isolated sessions to amortize startup and compilation. Do not reuse a browsing
context between tests until all WindowRealm, timer, message, cookie, cache, and
document-generation state has an explicit reset contract.

## Phase 0: repository and WPT pinning

Status: partial. The submodule path and reviewed allowlist exist. The checkout
must be initialized before an upstream run, the manifest/result do not expose
the WPT revision, and generated run records are not persisted yet.

1. Initialize the already-registered WPT checkout at `tests/wpt/upstream` with:

   ```sh
   git submodule update --init --depth 1 tests/wpt/upstream
   ```

2. Keep the exact submodule commit in normal Git metadata and copy its resolved
   revision into run metadata. Do not copy WPT into the repository or modify
   upstream tests.
3. Finish extending the manifest schema with a WPT revision and explicit test
   type. Path, mode, timeout, and exact expectation (`pass`, `fail`, `error`,
   `timeout`, `skip`) already exist. Keep reasons for every non-pass
   expectation.
4. Keep generated output outside committed fixtures, for example
   `tests/wpt/results/<run-id>.json`; ignore it and upload it from CI.
5. Continue excluding the submodule from Zibra's Markdown and formatting
   checks. WPT owns its own documentation and formatting rules.

## Phase 1: a real headless test session

Status: the process-per-test core is implemented in
`src/browser/wpt_session.zig`. It wraps a standalone `Browser` and:

- accepts an absolute URL, positive timeout, and the existing RTL option;
- creates one tab through `Browser.newTab`, preserving its ownership-transfer
  contract;
- drives the existing Browser/Tab task runners until an explicit test result,
  browser-drive error, or deadline;
- returns an independently owned structured result before Browser teardown;
- calls the normal shutdown path and joins Tab, presentation, accessibility,
  timer, XHR, and networking helpers before freeing borrowed owners.

Viewport, user-agent, origin-mode, and screenshot-policy configuration remain
future work. Initial navigation failures and uncaught script exceptions also
need observers so they become prompt structured `ERROR` results instead of
falling through to a deadline or infrastructure failure.

Do not use `process.exit`, arbitrary sleeps, or the screenshot loop's
two-consecutive-ready heuristic as the semantic completion condition.
Screenshot mode retains its own safety timeout, while WPT uses a per-test
deadline and distinguishes a semantic timeout from a browser crash.

The implemented CLI is:

```text
zibra --wpt-test <absolute-url> --wpt-timeout-ms <positive-n>
```

It emits exactly one line-delimited JSON object on stdout after normal
teardown; diagnostic logs stay on stderr. A dedicated result file descriptor
is unnecessary for the initial portable protocol.

## Phase 2: testharness completion and reporting

Status: the narrowly scoped native bridge and protocol transport are
implemented; upstream-harness proof, full diagnostics, revision metadata, and
result persistence remain open. When a WPT sink is installed, bootstrap
exposes a `completion_callback` compatible with testharness's external
completion dispatch and reports:

- each test name, status, numeric code, message, and stack;
- overall harness status (`OK`, `ERROR`, `TIMEOUT`, or
  `PRECONDITION_FAILED`);
- an aggregate `PASS`, `FAIL`, `ERROR`, or `TIMEOUT` status.

The process wrapper adds the exact requested URL, protocol version, duration,
empty/default diagnostic fields, and semantic timeout records. Still required
are the WPT revision, browser revision, assertion records, uncaught script
exceptions, rejected promises, console/network diagnostics, and start,
completion, and teardown timestamps.

The browser must not infer success from a title, painted text, process exit, or
DOM serialization. A harness result is complete only after the harness's own
completion signal, the outer JavaScript turn's fixed-point Promise-job
checkpoint, and the reporting Tab's serialized task-return/current-queue
barrier. This is not yet a general resource-quiescence guarantee, and Promise
jobs from another same-origin Realm do not yet switch Zibra's native
`current_window_id` routing.

Current protocol-v1 result shape:

```json
{
  "protocol_version": 1,
  "test": "http://web-platform.test:8000/dom/example.html",
  "status": "FAIL",
  "duration_ms": 42,
  "tests": [
    {
      "name": "...",
      "status": "FAIL",
      "code": 1,
      "message": "...",
      "stack": null
    }
  ],
  "harness": {
    "status": "OK",
    "code": 0,
    "message": null,
    "stack": null
  },
  "message": null,
  "console": [],
  "exception": null
}
```

`tests/wpt/run.py` strictly consumes one record, validates protocol version,
URL, status, and duration, compares the exact manifest expectation, and
reproduces raw stdout/stderr for failed or malformed runs. It still needs to
persist per-test records, revision metadata, raw diagnostics, and a run summary
outside committed fixtures.

## Phase 3: scheduling, quiescence, and cancellation

Status: partial. WPT is predominantly asynchronous, and the implemented
session uses the existing owners:

- `Tab` owns the serialized page work and its `TaskRunner` (`src/runtime/task.zig`).
- `src/script/js.zig` owns the generation-scoped `WindowRealm`, callback
  registries, and Kiesel lock.
- `src/script/timer_bindings.zig` and `script_tasks.zig` bridge timers and
  animation frames.
- `Browser` owns render scheduling and the presentation worker.

Implemented for the current slice:

1. The native callback copies only the first callback-scoped report into a
   mutex-protected pending candidate; it never tears down Browser state from
   the Tab worker.
2. The Session thread promotes that candidate only after the reporting task
   returns and the current serialized queue is empty. Deadline comparison
   happens first, so an undrained late report becomes semantic `TIMEOUT`.
3. Outer JavaScript entry points drain Promise jobs to a fixed point before
   releasing the active Realm and `JsLock`. Native re-entry defers to that
   outer checkpoint.
4. The existing host interrupt stops infinite script and Promise-job work
   during deadline teardown. Normal Browser shutdown then joins its workers
   while the Session callback context remains alive.
5. Unit coverage forces candidate races, deadline precedence, callback-byte
   ownership, malformed-report normalization, Promise ordering, timer
   delivery, and Promise-chain interruption without arbitrary sleeps.

Remaining requirements:

1. Audit every timer, interval, animation-frame, XHR, lifecycle, and message
   path for copied `DocumentHandle` generation identity and add focused stale-
   generation barriers where coverage is missing.
2. Add explicit initial-navigation, uncaught-exception, rejection, console,
   and network-error observers.
3. Give networking and detached helpers complete cancellation/transport
   deadlines so teardown cannot depend on the runner's outer watchdog.
4. Define a deterministic “no runnable work and no pending required resource”
   predicate for cases that require resource quiescence.
5. Route Agent jobs to the correct Zibra WindowRealm in same-origin
   multi-Realm cases, and associate any future multi-Tab report with its
   originating Tab before widening the current single-Tab session.

## Phase 4: JavaScript and DOM support in dependency order

Status: ongoing. The first slice now has `Promise`, fixed-point Promise-job
checkpoints, timers, basic events, console plumbing, and WPT-scoped
`self === window === globalThis`. `queueMicrotask`, complete exception and
rejection reporting, and many Web IDL details remain. Use served upstream
failures to choose the next coherent API slice.

Do not chase the full Web API surface first. Use WPT failures to grow the
smallest coherent vertical slices. The current bootstrap is
`src/script/runtime/bootstrap.js`; native binding domains are installed from
`src/script/native_bindings.zig`.

Prioritize:

1. **Harness essentials:** exceptions, `Error`, `Promise`, microtasks,
   `queueMicrotask`, timers, `EventTarget`, `Event`, `console`, and global
   `window`/`self` identity.
2. **DOM assertions:** `Document` and `Element` lookup, attributes, text and
   child topology, `createElement`, mutation, serialization, and correct
   `DOMException` names.
3. **Events:** capture/bubble ordering, listener removal, `once`, passive
   behavior, `preventDefault`, event targets, and exception containment.
4. **Web IDL behavior:** required arguments, conversions, nullable values,
   readonly properties, brand checks, and exact exception types.
5. **Page loading:** classic/defer/module script classification as supported,
   parser blocking, `DOMContentLoaded`, `load`, and `readyState`.
6. **Networking APIs:** `URL`, `fetch`, XHR, headers, request methods, body
   ownership, response status, and abort behavior.

The existing Realm rules are non-negotiable: each document gets a fresh
generation-scoped `WindowRealm`; raw Node pointers are synchronous borrows;
queued callbacks own copied arguments and generation handles; structural DOM
mutation retires or rebinds every affected handle before child storage moves.

## Phase 5: WPT HTTP server and origin model

Status: next milestone. The current file-URL runner cannot resolve WPT's
root-relative `/resources/` scripts and therefore cannot prove an unchanged
upstream test.

Use WPT's `wptserve` rather than a generic static server. It is required for
root-relative harness resources even before tests need headers, redirects,
cookies, dynamic responses, or multiple origins. The runner should start it on
worker-local ports, pass selected HTTP URLs to Zibra, and shut it down in a
`finally` path.

Implement and test the server-facing browser behavior in this order:

- URL resolution and serialized origins (`src/network/url.zig`);
- redirects and final URL ownership;
- response status, content type, charset, and body decoding;
- request headers and referrer policy;
- cookie selection, `Set-Cookie`, expiry, and HttpOnly visibility;
- same-origin checks and CORS preflight/response exposure;
- CSP and X-Frame-Options policy;
- iframe origins, `postMessage`, and parent/child browsing contexts;
- HTTPS and certificate behavior only when the transport/test environment is
  deterministic.

The existing network layer already has explicit origin, cookie, redirect, CORS,
CSP, and frame-policy seams. Preserve its ownership rules: response metadata
and body buffers are owned values, cookie-header snapshots are copied, and
cross-origin requests carry an explicit serialized request origin.

## Phase 6: semantic test selection and expectations

Status: partial. `run.py` supports reviewed `probe` and `testharness` modes,
positive per-test timeouts, exact `pass`/`fail`/`error`/`timeout`
expectations, explicit skips, and infrastructure-failure classification. The
committed manifest still contains no `testharness` case.

Start with tests whose dependencies match implemented behavior:

- HTML parsing and DOM tree construction;
- selectors, attributes, text, and basic events;
- CSS parsing and used-value/layout assertions where the test does not require
  unsupported scripting or platform fonts;
- URL, cookie, redirect, and same-origin unit-style tests served over HTTP.

Maintain separate buckets:

- `testharness`: structured JavaScript results;
- `reftest`: screenshot/reference comparison;
- `manual`: never claimed as automated conformance;
- `crashtest`: process health plus explicit completion;
- unsupported: recorded skip with a reason.

Use WPT metadata and test manifests to select files, but keep Zibra's reviewed
allowlist as the compatibility claim. A failure should normally become both a
WPT result and a focused Zibra regression (unit test, pipeline golden, or
manual fixture) according to `docs/testing.md`.

## Phase 7: rendering and reftests

Status: not started. Do not reuse semantic harness status as pixel evidence.

Rendering tests are a separate adapter, building on
`Browser.runToScreenshot` and `tests/screenshot_compare.zig`:

- make viewport dimensions, device scale, zoom, color scheme, fonts, and
  animation time explicit;
- wait for testharness/reftest completion and resource quiescence;
- capture only the page viewport, with chrome excluded;
- compare against a reference image with useful diff coordinates and a
  controlled tolerance policy;
- record platform, font inventory, renderer, and scale in the result.

Keep semantic assertions as the portable contract. Platform-font-dependent
pixels should not be the only evidence for a cross-platform behavior.

## Phase 8: runner performance and CI

Status: partial. The process-per-test protocol, local fixture validation,
runner unit tests, and portable `zig build check` integration exist. WPT server
groups, persisted reports, shards, artifacts, parallel workers, and a
persistent Zibra process do not.

The first process-per-test runner is intentionally slow but easy to debug. Once
results are correct:

1. Build Zibra once before the run.
2. Start one WPT server per worker group, not per test.
3. Use a persistent Zibra process with a fresh Browser/session per test, or
   prove a complete reset contract before reusing one.
4. Partition by manifest shard and cap concurrency around SDL/font and network
   ownership constraints.
5. Retry only infrastructure failures; never hide deterministic assertion
   failures with retries.
6. Publish JSON, logs, screenshots, and diffs as CI artifacts.

WPT contains tens of thousands of test files and far more subtests. A serial
process-per-test implementation can take many hours or days; a useful early
milestone is a small, stable feature shard, not an attempted full-suite run.

## Updated implementation order

Completed:

1. Headless one-test Session and protocol-v1 JSON result.
2. WPT-scoped completion bridge with synchronous and Promise-job fixtures.
3. Semantic deadline, task-return barrier, JS interruption, and normal
   teardown.
4. Strict runner parsing, exact expectation comparison, raw failure
   diagnostics, and local build integration.

Next:

1. Initialize the pinned checkout, expose its revision, and orchestrate
   `wptserve`.
2. Execute one reviewed, unmodified upstream `testharness.js` test through the
   existing protocol.
3. Add structured navigation, exception, rejection, console, and network
   failure reporting; verify served PASS, FAIL, ERROR, and TIMEOUT paths.
4. Persist per-test records, raw diagnostics, revision metadata, and a run
   summary.
5. Grow a small semantic DOM/events/timers shard and promote each discovered
   regression into focused native coverage.
6. Add resource-quiescence and multi-Realm routing contracts before tests that
   depend on them.
7. Add reftest capture, then sharding, parallelism, persistent processes, and
   CI artifact publishing.

## Verification requirements

For each browser-side phase, run the narrowest suite first:

- `zig build test-wpt-runner` for manifest, expectation, protocol, and
  infrastructure-failure classification;
- `zig build test-wpt` for the real synchronous PASS, Promise-job PASS, and
  semantic TIMEOUT process fixtures;
- `zig build test-script` for Realm, DOM, event, timer, and callback changes;
- `zig build test-network` for URL, HTTP, cookie, cache, and policy changes;
- `zig build test-browser` for Tab, navigation, lifecycle, and shutdown;
- `zig build test-pipeline` for layout/display-list behavior;
- `zig build test-screenshot` for native final-pixel behavior;
- `zig build check` before integration changes are merged.

At this progress snapshot, `zig build check --summary all` passed all 82 build
steps and 557 tests. The focused baselines were 111 `test-script` tests, 463
`test-browser` tests, three real `test-wpt` fixtures, and eight
`test-wpt-runner` cases.

Every WPT failure used to guide development should include the WPT URL,
revision, result JSON, relevant logs, and the promoted native regression. Never
replace a failing expectation with `skip` merely to make a shard green.
