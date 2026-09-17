# Testing and verification

Choose the narrowest deterministic check that reaches the changed boundary,
then expand verification in proportion to its ownership and visual risk. The
complete check does not replace a focused regression, and a screenshot does
not replace parser/layout assertions that explain a failure.

## Compatibility-driven development

Use representative-page failures and engine dependencies to select work; use
WPT to validate the selected capability. Raw pass counts are not a priority
score: a large parameterized suite can outweigh a missing API that prevents
whole applications from initializing.

For each coherent compatibility chunk:

1. Capture the first blocking script error or a concrete incorrect page
   behavior, preferably as a small deterministic fixture.
2. Identify the shared engine capability and its owner/invalidation contracts.
   Favor broad user-visible reach and dependency-unblocking value over isolated
   assertion gains.
3. Select relevant unchanged upstream WPT cases and record a bounded baseline.
   Distinguish unsupported features, semantic failures, page errors, semantic
   timeouts, and external watchdog/infrastructure failures.
4. Implement the capability with focused unit/lifetime coverage and a
   page-level regression. Re-run the same upstream cases and report limitations
   explicitly; do not change test expectations to conceal incorrect behavior.
5. Review related WPT suites when adding or substantially expanding an engine
   feature, including HTML parsing and SVG/layout/paint work. Update the
   [default allowlist](../tests/wpt/manifest.yaml) with newly meaningful
   directory prefixes or bounded explicit cases, considering all three runnable
   categories: testharness, reftest, and crashtest. Run the selected additions
   and record their baseline. Prefer a coherent subset over enabling an entire
   large domain with unsupported prerequisites for iteration. The default CSS
   selection deliberately covers the whole runnable corpus for periodic
   compatibility measurement; use focused manifests when iterating. Do not
   select only passing cases: semantic failures in implemented behavior are
   useful coverage, while
   unsupported automation or infrastructure must be identified separately.
   In the handoff, name the enabled coverage or explain why existing coverage
   is sufficient or which prerequisites prevent additions. A fetch/parse probe
   does not replace a conformance test. See the [WPT guide](../tests/wpt/README.md)
   for manifest and adapter details.
6. Expand to the relevant broader checks. Full WPT sweeps are periodic health
   checks, not the default loop for each edit.

Run native build/test jobs serially during agent work, with an outer
process-group watchdog and cleanup/reaping on success, timeout, and interrupt.
Do not leave background builds, watchers, servers, or browser children running.
Reuse the WPT runner's process supervision for upstream cases.

Defer performance scoring until correctness checks demonstrate that the
operation does real work. In particular, a geometry read must synchronously
update layout before a mutation-and-measure benchmark can measure that layout.
Unsupported or failed workloads are missing data, never zero-time successes.

## Check tiers

On macOS, `build.zig` uses the same `linkSdl` policy for the browser and native
tests. SDL2 and SDL_ttf are explicit dynamic dependencies. SDL_ttf's pkg-config
expansion is disabled because its dylib records its dependencies; expanding
them again can emit duplicate SDL2 Mach-O load commands through different search
paths and make dyld abort before the program starts. SDK library paths and
frameworks still come from the SDL build integration.

### Fast focused checks

Use a subsystem test step while iterating on a contained change. Focused steps
compile a smaller test root and make it harder to miss the direct regression:

- `zig build test-css-values` — complete lexical kinds, value normalization and bounded malformed-input handling without native libraries;
- `zig build test-css-syntax` — structural rule/declaration recovery without DOM or native libraries;
- `zig build test-css-declarations` — ordered blocks, shared property grammar, serialization and allocation failure cleanup without native libraries;
- `zig build test-css-supports` — feature-query boolean grammar, declaration admission, limits and allocation cleanup without native libraries;
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

Collector/thread lifetime regressions live in `src/tests/js_gc_threads.zig`.
Run `zig build test-script '-Dtest-filter=collector thread lifetime'` in a fresh
process to exercise concurrent first-use registration, first GC initialization
on a temporary JS worker, collection after worker exit, cross-thread host
destruction, and stack-only results while another thread collects. These are
also part of the unfiltered
script and unified suites. Tests that construct owning Chrome state must use
its constructor and keep its environment map alive through `deinit`; a partial
struct literal with an uninitialized FontManager is not a valid input fixture.

Audio core/controller tests use `zig build test-browser -Dtest-filter=audio`;
resource limits use `zig build test-network -Dtest-filter=bounded`. Regular tests
never open an audio device. The opt-in macOS silent native smoke test is described
in [audio verification](architecture/audio.md#verification).
`src/tests/browser_audio_controls.zig` drives native hit testing, zoomed dragging,
keyboard focus and paint-only progress on the real Tab worker with manual PCM.
Use `tests/manual/audio-controls.html` for visible control and listening checks.

### Portable complete checks

Run from the repository root:

- `zig build` after Zig or build-script changes;
- `zig build test` for the unified Zig suite;
- `zig build test-dump-dom` for the isolated HTML/DOM CLI contract;
- `zig build test-pipeline` for exact text-free style/layout/display-list
  goldens covering the box model, nested CSS zoom, bounded tables, float paint
  phases, and adjoining-margin/clearance flow under SDL dummy mode, plus
  narrow/wide cascade and inline-style cases;
- `zig build test-wpt-runner` for the dependency-free WPT manifest runner's
  protocol, expectation, diagnostic, and infrastructure-failure handling;
- `zig build test-csp` for loopback HTTP destination-specific CSP checks,
  allowed stylesheet/script/image/frame/XHR loading, and denied-request
  non-observation. It runs after the local WPT protocol fixtures and uses the
  same bounded browser-process supervisor;
- `zig build test-referrer` for loopback HTTP policy headers, parser/meta
  delivery order, per-resource overrides, redirect suppression, stylesheet
  provenance, and incoming document referrers. It follows the CSP/local WPT
  fixtures serially with the same process supervisor;
- `zig build test-wpt` for local headless synchronous PASS, Promise-job PASS,
  TIMEOUT, startup/error diagnostics, partial results, and Unicode JSONL
  fixtures, plus live body replacement/title accessors, JavaScript rectangles,
  client/offset box metrics,
  context-sensitive HTML fragments and retained dynamic-markup identities,
  CharacterData edits with live Range repair and synchronous text reflow,
  live dataset writes/deletes with attribute-selector restyling and geometry,
  measure-to-position interaction, native-editor client clips, empty inline
  insertion points, and parser-boundary regressions.
  Captures are serial and process-watchdog bounded.
  This step uses no upstream WPT checkout
  or network access;
- `task wpt-all` for a long-running local compatibility sweep. It builds once,
  discovers upstream testharness, reftest, and crashtest cases, and runs bounded
  browser workers in parallel; use `WPT_JOBS=N` to tune concurrency and inspect its checkpointed
  report under `tests/wpt/results`. The runner keeps normal output compact,
  records completion for each top-level WPT folder, and accepts `--verbose`
  for per-failure browser diagnostics;
- `task wpt-smoke` for one unchanged upstream case per adapter, run serially
  through the real executable with `--fail-on-unexpected` as a strict result
  gate. This requires the initialized WPT checkout and
  its server dependencies; see the [WPT guide](../tests/wpt/README.md).
- `task wpt` for the reviewed allowlist across all three runnable categories.
  It runs selected directories and explicit cases, but scores every discovered
  directory in the report; omitted directories appear as `0/N`. Completed
  result-collection runs exit 0 regardless of test failures or missing coverage;
  compatibility scores and per-case infrastructure failures remain in the
  report. Runner setup, report-writing, and interruption failures still exit
  nonzero. See the [WPT exit-status contract](../tests/wpt/README.md#run-completion-versus-compatibility-results);
- `zig build test-docs` for repository Markdown links when documentation
  changes. The checker intentionally skips the vendored `tests/wpt/upstream`
  submodule, whose links are resolved by WPT's own documentation tooling;
- `zig build test-server` after tutorial server routing, topic, session,
  message, or persistence changes (the underlying direct unittest command is
  `python3 -m unittest tests/test_server_message_board.py`).

`zig build verify` is the agent-oriented portable aggregate: build/install,
format checking, the unified unit suite, focused-root compilation, DOM and
pipeline goldens, local WPT runner/protocol and loopback CSP checks, server
tests, and Markdown links. Native visual goldens remain separate because they are
platform-dependent.

The aggregate is intentionally not named `check`: language servers may run
that step automatically, which would launch the full test suite on edits.

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

All inspection and browser modes use Zibra's native CSS parser. The
[pipeline manifest](../tests/pipeline/manifest.zig) includes narrow/wide
[cascade fixtures](../tests/pipeline/css-cascade.html) for declaration order,
escaped property names, shorthand expansion, variables, inline declarations and
nested media conditions. Keep their exact goldens when refactoring CSS owners.

`zig build test-document` includes native stylesheet replacement and restyle
allocation-failure regressions. The render suite's `Native CSS inspection` test
checks real geometry, paint and software pixels across viewport/source changes.
The [CSS recovery fixture](../tests/manual/css-recovery.html) checks declarations
after nested unknown at-rules and blocks closed at EOF. Both bars must be green
and 120px wide; its style, layout and display list are pipeline goldens.
The [ordered declaration WPT manifest](../tests/wpt/manifest-css-declarations.yaml)
covers live inline CSSOM, shorthand priority, serialization, clone isolation and
crash safety. Run all categories serially against the built binary. The
[interactive declaration page](../tests/manual/css-declarations.html) checks
pending shorthand edits and invalid setters through synchronous geometry reads
and runs in `test-wpt`; `src/tests/css_style.zig` also covers native ownership
and computed readback.

The [structural syntax WPT manifest](../tests/wpt/manifest-css-structure.yaml)
covers computed declarations, EOF recovery, bracket matching and malformed-input
crashes. The same cases are enabled in the default allowlist. CSSOM insertion
tests remain separate because retained stylesheet objects are not implemented.

The focused [syntax](../tests/wpt/manifest-css-frontend.yaml) and
[interop](../tests/wpt/manifest-css-interop.yaml) WPT manifests retain their
upstream cases and PASS expectations. They exercise the native browser; a
successful inspection capture does not establish an upstream WPT pass. The
[CSS plan](../CSS_PLAN.md) describes the remaining syntax and CSSOM work.

The [logical selector fixture](../tests/manual/css-selectors.html) checks shared
DOM queries, forgiving lists, explicit specificity and geometry after ancestor,
sibling and inline mutations. Document tests cover selector ownership, An+B
admission, cache equivalence and cascade provenance; script/render tests carry
those semantics through synchronous style reads and software pixels.

The [color fixture](../tests/manual/css-colors.html) checks live resolved
readback, named colors, alpha, currentcolor inheritance and variable fallback.
It runs in the local WPT gate; native render coverage also verifies retained
background recoloring without geometry invalidation. The
[focused color manifest](../tests/wpt/manifest-css-colors.yaml) covers
rendering, keyword parsing and computed-value helpers using `CSS.supports`.

The [feature-query fixture](../tests/manual/css-supports.html) checks both
`CSS.supports` overloads, conditional rule activation, selector capability and
matching media-dependent geometry. It runs in the local WPT gate. Native tests
cover strict selector admission, nested rule/keyframe order, source replacement,
software pixels and allocation failure cleanup. The
[focused supports manifest](../tests/wpt/manifest-css-supports.yaml) includes
unchanged API, rendering, variable and malformed-input cases plus computed-color
helpers newly able to reach value assertions. CSSOM rule-identity and CSS nesting
prerequisites remain distinct from feature-query evaluation.

The [CSS completion fixture](../tests/manual/css-completion.html) checks color
calculations, nested-selector invalidation, animation fill changes and native
scroll/sticky geometry in the local WPT gate. The corresponding
[upstream selection](../tests/wpt/manifest-css-completion.yaml) covers color and
animation value helpers, nested conditional rules, sticky constraints and
rendering/crash cases. Unsupported CSSOM selector mutation and scroll-linked
animation prerequisites remain diagnostic; preserve PASS expectations and
distinguish them from semantic failures in implemented behavior.

The [modern color fixture](../tests/manual/css-modern-colors.html) checks
original-space CSSOM serialization, custom properties/currentcolor after sheet
replacement, inherited font calculations and modern animation endpoints. Its
[upstream selection](../tests/wpt/manifest-css-modern-colors.yaml) covers valid,
invalid and computed HWB/Lab/predefined-space values, native color references
and the existing malformed SVG-color crashtest. Review computed/paint results
separately: original-space readback must not expose the gamut-mapped RGBA8 value.

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

For resumable or multi-machine WPT collection, use the generated
[GNU Parallel batches](../tests/wpt/README.md#resumable-batches-with-gnu-parallel).
The existing manifest remains the selection source; batch plans are run artifacts.
