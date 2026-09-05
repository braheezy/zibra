# Testing and verification

Choose the narrowest deterministic check that reaches the changed boundary,
then expand verification in proportion to its ownership and visual risk. The
complete check does not replace a focused regression, and a screenshot does
not replace parser/layout assertions that explain a failure.

## Check tiers

### Fast focused checks

Use a subsystem test step while iterating on a contained change. Focused steps
compile a smaller test root and make it harder to miss the direct regression:

- `zig build test-document`
- `zig build test-render`
- `zig build test-network`
- `zig build test-script`
- `zig build test-browser`

The root `build.zig` remains authoritative and `zig build --help` displays the
steps.

Add `-Dtest-filter=substring` for a narrow Zig unit-test iteration, for example
`zig build test-render -Dtest-filter=responsive`. This filters test names, not
pipeline or screenshot cases. Remove the filter for broader verification and
report filtered runs separately from complete subsystem checks.

When changing one pure helper, run its focused subsystem test first. Add a unit
test close to the owner or in the matching `src/tests/` module. Tests should
force the state transition under review rather than depend on process exit,
arena behavior, or arbitrary sleeps.

### Portable complete checks

Run from the repository root:

- `zig build` after Zig or build-script changes;
- `zig build test` for the unified Zig suite;
- `zig build test-dump-dom` for the isolated HTML/DOM CLI contract;
- `zig build test-pipeline` for exact text-free style/layout/display-list
  goldens covering the box model, nested CSS zoom, bounded tables, float paint
  phases, and adjoining-margin/clearance flow under SDL dummy mode;
- `zig build test-wpt-runner` for the dependency-free WPT manifest runner's
  protocol, expectation, diagnostic, and infrastructure-failure handling;
- `zig build test-wpt` for local headless synchronous PASS, Promise-job PASS,
  and TIMEOUT result-protocol fixtures. This step uses no upstream WPT checkout
  or network access;
- `task wpt-all` for a long-running local compatibility sweep. It builds once,
  discovers upstream testharness cases, and runs bounded browser workers in
  parallel; use `WPT_JOBS=N` to tune concurrency and inspect its checkpointed
  report under `tests/wpt/results`. The runner keeps normal output compact,
  records completion for each top-level WPT folder, and accepts `--verbose`
  for per-failure browser diagnostics;
- `task wpt` for the reviewed directory allowlist. It runs only selected WPT
  directories, but scores every discovered directory in the report; omitted
  directories appear as `0/N` and keep the suite failing until implemented;
- `zig build test-docs` for repository Markdown links when documentation
  changes. The checker intentionally skips the vendored `tests/wpt/upstream`
  submodule, whose links are resolved by WPT's own documentation tooling;
- `zig build test-server` after tutorial server routing, topic, session,
  message, or persistence changes (the underlying direct unittest command is
  `python3 -m unittest tests/test_server_message_board.py`).

`zig build check` is the agent-oriented portable aggregate: build/install,
format checking, the unified unit suite, focused-root compilation, DOM and
pipeline goldens, local WPT runner/protocol checks, server tests, and Markdown
links. Native visual goldens remain separate because they are
platform-dependent.

For document-pipeline changes, run `test-pipeline`; use
`tests/manual/dump-pipeline.html` interactively when diagnosing a stage not
represented by the box-model or nested-zoom goldens. The inspection stages
deliberately stop before Browser construction; preserve that isolation.

Dump and screenshot modes accept `--viewport WIDTHxHEIGHT` (default 800x600,
each dimension 1–8192). Dumps use the entire size for document geometry and
width/height media queries. Screenshots use that presentation size, with the
browser chrome subtracted from the document's height, just like a native
window. For example:
`zig build run -- --viewport 2560x1440 --screenshot /tmp/wide.png URL`.
Always verify a wide viewport when diagnosing content stuck in a narrow window.

### Native macOS visual checks

On macOS, run `zig build test-screenshot`. It exercises the windowless
software-rendering path and compares platform-specific PNG goldens. A
screenshot test is appropriate when exact paint, glyph placement, clipping,
effects, or final composition is the behavior under review.

For pages that intentionally keep timers or animations active, use the CLI's
bounded diagnostic capture instead of waiting for quiescence:
`zig build run -- --screenshot /tmp/page.png --screenshot-after-ms 3000 URL`.
It captures the current fully presented frame at or after the requested delay
and retains the normal 30-second timeout only as a load-safety fallback.
Windowless captures wait for the document lifecycle to reach `complete` and
for a sustained quiet interval, so pages driven by short timers are not
captured between two updates.

Do not make a cross-platform semantic assertion depend only on font-dependent
pixels. Prefer a DOM/style/layout/display-list assertion for the portable
contract and use the screenshot as the final visual layer.

### Manual interaction fixtures

`tests/manual/` contains small pages for behavior requiring input, animation,
multiple frames/windows/origins, timing, networking, or human visual judgment.
Each primary fixture must include a short `How to verify` comment and make its
expected result visible and deterministic. Supporting child/target/resource
files need not duplicate the primary instructions.

The [manual fixture catalog](../tests/manual/README.md) maps primary pages to
their purpose and any server or trace requirement. Use it to find an existing
regression before adding another page.

## Baseline pages

- `tests/manual/acid1-box-model.html` is the broad CSS/box-model compatibility
  baseline. Its presence and manual appearance are not, by themselves, an
  automated Acid1 pass. Prefer adding portable layout/display-list assertions
  for regressions discovered through it and retain a screenshot check for the
  integrated visual result.
- `tests/manual/css-zoom.html` and its child fixture cover authored subtree
  zoom composed with browser accessibility zoom. Changes in CSS lengths,
  fonts, controls, frames, focus geometry, hit testing, media width, retained
  paint, or screenshot preview should include this baseline.
- `tests/manual/dump-pipeline.html` is the stage-isolation baseline for style,
  layout, and display-list diagnostics.
- `tests/manual/lifecycle-long-timeout.html` is the shutdown baseline for
  cancellation of long timer helpers.

Do not claim compatibility from a manual fixture alone. Record whether the
evidence was unit, golden, screenshot, trace, local-server, or human inspection.

## What to add

| Change | Preferred regression |
| --- | --- |
| Parser, serializer, selector, CSS grammar | Unit test plus DOM/style golden when output is user-visible |
| Pure layout geometry or used-value helper | Unit test and layout/display-list golden |
| Paint command or ownership | Unit test for command shape/cleanup; screenshot only for final pixels |
| Navigation, URL, cache, cookie, security header | Unit test with data/file URL or deterministic local server |
| DOM mutation or invalidation | Handle/lifetime unit test plus a visible manual fixture |
| Tasking, shutdown, or worker ownership | Barrier/condition-based concurrency test that proves cleanup and join |
| Input, focus, iframe, animation, or multi-window behavior | Deterministic manual fixture, plus unit coverage for the state machine |
| Tutorial server | Python unittest without binding a public port |

Use `std.testing.allocator` or another reclaiming allocator for owned
containers and teardown. Production arena success can conceal leaks or stale
borrows.

## Golden rules

`tests/golden/` contains committed deterministic outputs. Update a golden only
after inspecting the difference and confirming the behavior change is
intentional. Never regenerate a golden merely to make a failing check green.

Keep goldens stage-specific and human-reviewable where possible. If a complete
display dump is unstable or unnecessarily large, assert the smallest semantic
subset that proves the contract.

## Before handing off a change

1. Run the focused test for the owner being changed.
2. Run `zig build` and the portable aggregate/full suite appropriate to the
   change.
3. Run pipeline goldens for parser/style/layout/paint work.
4. Run native macOS screenshots for pixel-sensitive work.
5. Exercise the relevant manual fixture when automation cannot reproduce the
   interaction.
6. Report exactly which checks ran, which were unavailable, and which behavior
   remains manually verified.
