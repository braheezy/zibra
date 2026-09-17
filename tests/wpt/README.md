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

### Run completion versus compatibility results

By default, a completed run exits **0**, regardless of its case-level `FAIL`,
`ERROR`, `TIMEOUT`, `CRASH`, or `INFRA` results. Missing coverage under
`--full-suite` also does not fail the command. These results remain unchanged
in the console and JSON report: `complete` describes run completion, while
`summary.suite_failed` describes compatibility/coverage, not runner success.

Invalid arguments/manifests, a missing checkout, server startup failure,
report-writing failure, and interruptions still exit nonzero. An isolated
browser/session failure recorded as `INFRA` is different from a failure that
prevents the runner from completing its work or saving the requested report.

Use `--fail-on-unexpected` for a strict gate: it exits 1 for unexpected case
results (including `INFRA`) or unselected full-suite coverage. Reviewed
expected deviations still match normally. `task wpt-smoke` uses this flag;
the result-collection tasks (`wpt`, `wpt-all`, `latest-results`, category runs,
`dom-results`, and `acid3-results`) use the default completion-based status.

### Focused compatibility manifests

The [cascade-layer manifest](manifest-css-layers.yaml) covers named/anonymous
ordering, important reversal, style nesting, repeated linked sheets and statement
recovery. Its seven default-enabled files pass (44/44 assertions), up from two
files and 6/44 assertions. Normal and important sharing reftests both render the
expected green square. Named window globals block the upstream inline/keyframe
cases; the media-toggle reftest has an unstyled XHTML/CDATA reference. Their
engine behavior is covered by unit tests and the local six-assertion page.
CSSOM, imports, adoption, other named at-rules and rollback remain distinct
prerequisites; see the [layer review](../../CSS_PLAN.md#cascade-layers).

The [retained stylesheet manifest](manifest-css-stylesheets.yaml) covers live
style-element media, conditional source order, nesting and malformed supports
recovery. It passes 8/8 files (8/8 assertions), up from 6/8 files (5/8 assertions).
The default allowlist adds both style-media tests and `at-media-001/002` reftests.
Existing malformed-supports crashtest coverage is retained. CSSOM sheet identity
and link load-event tests remain blocked on those APIs; the no-refetch behavior
has a deterministic loopback regression in `test-referrer`. See the
[CSS plan](../../CSS_PLAN.md#retained-stylesheet-programs-and-live-media) for the
reviewed exclusions and remaining capabilities.

[`manifest-css-declarations.yaml`](manifest-css-declarations.yaml) selects five
inline CSSOM testharness files, a clone-isolation reftest and a declaration-block
crashtest. All seven are enabled in the default allowlist. The comparison improved
from 2/7 to 6/7 passing files and 6/19 to 16/19 passing assertions, with no errors,
crashes, timeouts or infrastructure failures. Use `--mode all --jobs 1`;
`--fail-on-unexpected` exits nonzero for the remaining upstream failure.

`css-style-attr-decl-block.html` still fails two MutationObserver assertions and
its base-URL test first encounters missing computed `backgroundImage` readback.
Its `all:unset`/`all:revert` comparison passes because both unsupported `all`
declarations are ignored, so that assertion does not establish `all` support.
The declaration-block crashtest likewise has limited reach until computed-style
enumeration is implemented. The host/unit tests and
[regression page](../manual/css-declarations.html) directly exercise ordered
longhands, pending shorthand ownership and native layout instead. Whole
stylesheet/rule CSSOM and additional property grammars remain separate slices.

[`manifest-css-values.yaml`](manifest-css-values.yaml) selects five testharness
files for EOF recovery, token boundaries, custom URL data, specified-value
serialization and numeric colors, plus two escaped-value reftests and an escape
crashtest. The seven new cases are enabled in the default allowlist; the
crashtest was already enabled. Run with `--mode all --jobs 1`.

The focused comparison improved from 2/8 to 5/8 passing files and from 432/794
to 539/794 passing assertions, with no assertion regressions, errors, crashes,
timeouts or infrastructure failures. `serialize-values.html` retains unsupported
property and shorthand serialization failures. At that checkpoint,
`color-valid.html` failed the four-argument `rgb()` alias and `light-dark()` cases,
and `escaped-ident-spaces-001.xht` needed escaped selector identifiers. The
grammar slice below addresses aliases and selectors. Keep these upstream
PASS expectations unchanged. Stylesheet-identity-dependent serialization cases
were reviewed but not newly enabled because they exercise the older stylesheet
shim. Native unit/host tests and the [value regression page](../manual/css-values.html)
cover owned normalized declarations, escaped custom names, malformed input,
resource URL decoding and immediate layout independently of that shim.
The declaration and structural manifests were rerun alongside the value suite
and retained the results recorded here, without new errors or failures.

[`manifest-css-grammar.yaml`](manifest-css-grammar.yaml) covers escaped
selectors, absolute RGB/HSL grammar and serialization, and single-layer
background positions: seven testharness files, six reftests and an existing
escape crashtest. Run with `--mode all --jobs 1`. Eleven cases were newly
enabled in the default allowlist; the DOM escape suite, one escaped-value
reftest and the crashtest were already included. Related background/color
crashtests were reviewed, but their stylesheet shim, multiple-layer, animation
or unsupported SVG prerequisites do not exercise this slice fully.

The [native page](../manual/css-grammar.html) also checks escaped-selector
attribute mutations with synchronous layout, custom-property color substitution,
background shorthand round trips and bordered image positioning. Native
owner/render tests cover allocation failures, stylesheet replacement, alpha
precision, used fonts/zoom, negative percentage bases and extreme signed tile
offsets. Typed color math and exact surrogate preservation in DOM attribute
storage remain separate capabilities; upstream PASS expectations are unchanged.

The saved-browser comparison improved from 3/14 to 11/14 passing files and
from 133/292 to 228/292 passing assertions, without regressions, errors, crashes,
timeouts or infrastructure failures. All six reftests and the crashtest pass.
Both background-position grammar suites and both invalid-color suites pass.
The remaining 64 assertions are 62 typed-color-math cases and two selectors
whose DOM attribute values contain lone UTF-16 surrogates. The latter reach
the selector as replacement characters because attribute storage loses those
original code units; changing CSS escape decoding would be incorrect.

The earlier value manifest was rerun against this implementation: it improved
from 5/8 to 6/8 passing files and from 539/794 to 628/794 passing assertions,
also without regressions or infrastructure failures. Its remaining files cover
unsupported property/shorthand serialization and `light-dark()`; both escaped
identifier reftests and the four-argument `rgb()` alias now pass.

[`manifest-css-selectors.yaml`](manifest-css-selectors.yaml) reviews logical
selector lists, specificity, invalidation and nth-formula recovery. On
2026-09-12 its 17 cases improved from 6 to 8 passing files compared with the
saved pre-change browser: nested logical/link styling and the negated-is
ancestor-change reference now pass. All four references and all three crash
cases pass; there are no regressions, engine crashes, runner errors or
infrastructure failures. Only 22 testharness assertions execute: 1 passes,
19 fail on missing named Window globals during parser-time scripts, and 2 stop
at computed named-color serialization (`green` versus `rgb(0, 128, 0)`). Two
additional files time out after named-global script errors before assertions
run. These are prerequisites, not evidence of failed selector matching.

Eight CSS cases are newly enabled in the default allowlist: the sibling
invalidation test, four references and three crash cases. The focused
manifest retains the other cases for diagnosis; their global-access blockers
are not hidden by altered expectations. DOM query receiver exclusion was
already covered by the default `dom` directory. Selector-text CSSOM parsing,
namespace/shadow suites and nth `of` lists were reviewed but remain outside
this implementation. The native tests additionally cover the static-specificity
cascade from `is-specificity.html` without its named-global prerequisite.

The [logical-selector page](../manual/css-selectors.html) passes five local
checks through native DOM queries and immediate geometry reads after
ancestor/sibling and inline changes. It is part of `zig build test-wpt`.

[`manifest-css-supports.yaml`](manifest-css-supports.yaml) covers both
`CSS.supports` overloads, recursively strict selector queries, CSSStyleDeclaration
consistency, boolean rule activation, media nesting, invalid child-rule recovery,
keyframes, variable values and malformed supports blocks. It also includes five
computed-color files previously blocked by the absent API. Run with
`--mode all --jobs 1 --timeout-ms 60000`. The initial feature-query work enabled 48 of these
50 cases. The original comparison improved from 3/50 to 45/50 passing files
and from 133/5933 to 5858/5933 passing assertions, without crashes, timeouts or
infrastructure failures. Its remaining gaps motivated the implementation below:
nesting in `at-supports-048.html`, animation fill modes in
`at-supports-content-003.html`, RGB/HSL computations and sticky positioning.

The suite review also covered conditional CSSOM/IDL and `conditionText` tests,
namespace cases, font queries, `@font-face`/`@counter-style` children and quirks
mode. These need persistent stylesheet/rule objects, namespace ownership,
downloadable fonts/counters or document-mode grammar that this slice does not
supply. They were not broadly enabled. Native tests cover source/keyframe
ownership and allocation-failure publication; the
[feature-query page](../manual/css-supports.html) covers API/rule agreement and
media-dependent native geometry in the local WPT gate.

### Color calculations, nesting, animation and sticky

[`manifest-css-completion.yaml`](manifest-css-completion.yaml) selects 57
unchanged upstream cases across testharness, rendering and crash coverage.
The default allowlist gains 45 explicit cases, including the two conditional
references previously waiting on nesting and animation fill modes. Coverage
includes computed/specified RGB/HSL, animation longhand parsing/computation,
nested rule order and invalidation, and sticky scrolling/containing limits.
CSSOM selectorText mutation (`invalidation-004.html`), the combined automatic
duration/scroll-timeline file, two implicit-nesting tests using named window
globals and `position-sticky-top-004.html` with its CDATA-bearing XHTML reference
remain focused diagnostics because their prerequisites are not implemented.
Their PASS expectations remain intact. Run with `--mode all --jobs 1
--timeout-ms 60000`; the large computed-HSL matrix can exceed the default
10-second session deadline.

With the same 60-second per-case limit, the saved-browser comparison improves
from 14/57 to 41/57 passing files and from 3938/4154 to 4063/4154 passing
assertions. No previously passing file regresses. The final report has 15
failing files and one error in the automatic-duration/scroll-timeline diagnostic,
with no crashes, timeouts or infrastructure failures. The nesting references,
all three fill-mode files and the vertical sticky testharness cases pass.
The stacking-context reference improves from 44,400 to 8,800 differing pixels;
its remaining absolute-position geometry mismatch is kept visible.

The original 50-file feature-query selection now passes 48/50 files and
5929/5933 assertions, up from 45/50 and 5858/5933. Its only four remaining
assertion failures require container-unit color math. Both formerly diagnostic
conditional references and positive sticky parsing now pass.

The native implementation and remaining boundaries are recorded in the
[CSS plan](../../CSS_PLAN.md#color-calculations-nesting-animation-phases-and-sticky-positioning).
Container units, canonical relative-expression serialization and atomic-inline
sticky geometry still produce useful semantic failures. Some specified-color
cases retain older missing-component serialization expectations; the current
[CSS Color draft](https://drafts.csswg.org/css-color-4/#serializing-sRGB-values)
preserves `none` via `color(srgb ...)` or percentage-bearing modern HSL. These
expectations are reported unchanged, separately from missing arithmetic support.
Specifically, 16 previously passing specified-RGB assertions and nine HSL
assertions now disagree with those older missing-component expectations;
computed missing-component cases pass. This is a documented serialization
choice, not a claim that every upstream assertion improved.
The local [`css-completion.html`](../manual/css-completion.html) fixture checks
native geometry and live edits without upstream CSSOM/timeline prerequisites.

### Calculation serialization and color interpolation

[`manifest-css-color-interpolation.yaml`](manifest-css-color-interpolation.yaml)
selects 24 unchanged upstream cases: 15 testharness files, eight references and
the existing malformed SVG-color crashtest. The saved-browser baseline passes
3/24 files and 5079/6948 assertions, without harness errors, crashes, timeouts
or infrastructure failures. Run with `--mode all --jobs 1 --timeout-ms 120000`.

The final build passes 12/24 files and 6854/6948 assertions: 1775 additional
assertions pass, with none lost. Mix computation, invalid-mix admission, all
18 out-of-gamut assertions, missing-component computation and six native
references pass. There are no harness errors, crashes, timeouts or infrastructure
failures. The unchanged 35-case modern-color selection also improves from
28/35 files and 1173/1320 assertions to 29/35 and 1291/1320, with no losses.

The default allowlist adds five mix parsing/computation files and seven
references. `color-mix-basic-001.html` remains a focused diagnostic because its
reference constructs expected colors with unsupported `Element.animate()`;
it is excluded from the default allowlist. The native test page paints, but
that reference throws before creating its comparison rows. The runner records
a reftest failure; this is an API prerequisite, not a mixing discrepancy.
Related animation suites require `getAnimations()` and WAAPI, so no additional
animation suite is enabled on the strength of the scalar sampler alone.
No additional relevant standalone color crashtest was found.

The non-sRGB reference has a bounded gamut-mapping difference: its first equal
LCH mixture expects fixed RGB(145,116,0), while native CSS Color 4 gamut mapping
paints RGB(143,117,0). The other eight rows match. Preserve the reference and its
PASS expectation; do not replace the mapping algorithm with clipping for it.

Specified tests also retain older missing-component and percentage-free
HSL/HWB expectations. Remaining exact-serialization gaps include decimal
precision and upper-range HSL components inside a contextual expression.
The remaining 94 assertions comprise 52 missing-component serialization
differences, 20 percentage-bearing contextual HSL/HWB serializations, two
contextual HSL cases that also expose upper-range clamping, four exact hue
decimal differences, and 16 unsupported container-unit calculations.
Container-relative calculation units remain unsupported. The
[local fixture](../manual/css-color-interpolation.html) runs in `test-wpt` and
covers actual computed values, font/currentcolor inheritance, live theme edits,
hue paths, zero/partial percentages and paused modern/legacy animations.
Engine tests additionally cover independent declaration storage/CSSOM
presentation, allocation failure, source retirement and retained paint.
See the [CSS plan](../../CSS_PLAN.md#calculation-serialization-color-mixing-and-interpolation)
for the complete scope and ownership boundaries.

### Modern absolute color spaces

[`manifest-css-modern-colors.yaml`](manifest-css-modern-colors.yaml) selects
35 unchanged cases: nine valid/invalid/computed HWB, Lab-family and `color()`
files, 25 native conversion references, and the already-enabled malformed
SVG-color crashtest. The default allowlist gains the nine value files and all
25 references. Other color-mixing/relative-color, HDR, canvas-space, custom
profile and stylesheet-API suites require capabilities outside this slice;
no additional relevant standalone crashtest was found.

Run with `--mode all --jobs 1 --timeout-ms 60000`. The saved-browser baseline is
4/35 passing files and 235/1320 passing assertions, without errors, crashes,
timeouts or infrastructure failures. The final build passes 28/35 files and
1173/1320 assertions, with no errors, crashes, timeouts or infrastructure
failures and no previously passing assertions lost. All invalid-value files,
24/25 rendering references and the crashtest pass. The
[page fixture](../manual/css-modern-colors.html) checks native live theme/font
updates and modern keyframe endpoints. The
[CSS plan](../../CSS_PLAN.md#modern-absolute-color-spaces) records the numerical
conversion owner, sRGB framebuffer boundary and remaining interpolation limits.

Some checked-in HWB expectations predate the current draft's percentage-bearing
missing-component serialization. The Rec.2020 reference also predates the
current display-referred BT.1886 transfer function. Preserve those expectations
and report these differences separately from missing arithmetic or paint bugs.
Specified calculation serialization remains incomplete: constant calculations
resolve too early, and relative-unit calculation trees are not canonically
reordered. Computed container-unit cases remain unsupported. The LCH/OKLCH
radian cases also compare against fewer serialized hue digits.
The 147 remaining assertions comprise 122 specified-calculation serialization
cases, 12 container-unit cases, four hue-precision comparisons and nine HWB
missing-component comparisons. The earlier 57-case CSS completion selection
retains every file and assertion status (41 passing files, 15 failures, one
existing error; 4063/4154 assertions passing).

[`manifest-css-colors.yaml`](manifest-css-colors.yaml) covers resolved sRGB
color values and currentcolor inheritance/paint. Its bounded selection includes
invalid named keywords, computed colors, the existing selector invalidation
test, named/currentcolor/transparent references and malformed SVG color syntax.
Run with `--mode all --jobs 1`. Default coverage adds invalid named-color parsing,
`named-001.html`, `currentcolor-001.html`, `currentcolor-002.html`, and
`crashtests/stop-color-invalid-rgb.html`. The selector case was already enabled.

The five computed-color helper files now reach values through native
`CSS.supports` and are enabled by default as part of feature-query coverage.
The older XHTML references also exercise the known CDATA stylesheet-loading gap;
a matching pair does not prove that its CDATA-wrapped rules were styled.
Modern HTML currentcolor references and the
[native color page](../manual/css-colors.html) avoid that prerequisite.

The saved-browser comparison improved from 3/16 to 5/16 passing files and
184/4515 to 186/4515 passing assertions, without regressions, timeouts, crashes
or infrastructure errors. Named-color rendering and selector invalidation now
pass. All 4329 remaining assertions stop at missing `CSS.supports`.
Both modern currentcolor references improve from 36315 differing pixels to
231 pixels with a maximum channel delta of one. A temporary diagnostic removing
their same-color text matches the unmodified green-square reference exactly,
isolating the remaining difference to glyph compositing precision. These
upstream references still count as failures; no tolerance or expectation changed.

The native page runs in `zig build test-wpt` and covers copied/live readback,
alpha, names, custom substitution and ancestor mutations. Retained-render tests
check background recoloring while geometry stays clean. System colors, relative
and wide-gamut colors, typed color math, missing RGB component preservation and
full color animation/interpolation remain separate capabilities; upstream
expectations are unchanged.

[`manifest-css-structure.yaml`](manifest-css-structure.yaml) covers structural
CSS recovery with one testharness case, five reftests and two crashtests. Use
`--mode all --jobs 1 --fail-on-unexpected`; all eight cases also appear in the
default allowlist. The initial implementation improved the focused result from
5/8 to 7/8 passing cases. `matching-brackets-001.xht` still fails because the
document loader passes its XHTML CDATA wrapper into CSS; removing just that
wrapper in an isolated HTML diagnostic produces the expected computed colors.
Keep this integration gap visible with the unchanged upstream PASS expectation.
See the [CSS plan](../../CSS_PLAN.md) for syntax, ownership and CSSOM boundaries.

[`manifest-dataset.yaml`](manifest-dataset.yaml) selects six HTML `dataset`
files covering live data-* reflection, name conversion, deletion, enumeration,
and prototype behavior. These six cases are also in the default allowlist.
The 2026-09-07 comparison improved from 0/6 to 6/6 passing files and from
1/42 to 42/42 passing assertions, with no errors, timeouts, crashes, or
infrastructure failures in either six-file run.
The generated `dataset-binding.window.js` case is not yet enabled: explicit
testharness entries currently lose generated source/entry URL metadata. Its
descriptor/prototype-setter checks are covered by native-host regressions.
The local [`dataset.html`](../manual/dataset.html) fixture additionally checks
attribute-selector restyling before geometry reads. There are no dedicated
dataset reftests/crashtests in this checkout; the in-page checks exercise real
native storage and rendering without adding unrelated suites. The interface
does not claim full prototype IDL, explicit non-configurable property
definitions, custom-element reactions, or MutationObserver delivery.

[`manifest-character-data.yaml`](manifest-character-data.yaml) checks Text and
CharacterData mutations, DOMString conversions, surrogate splitting/rejoining,
constructors, and normalization. The 2026-09-07 testharness comparison improved
from 1/14 to 13/14 passing files and 34/188 to 187/188 assertions. The remaining failure
is the iframe-global Text constructor, not data mutation. There were no errors,
timeouts, crashes, or infrastructure failures in this focused run. The manifest
also selects the existing `dom/crashtests/normalize-crash.html` case for
`--mode all` or `--mode crashtest` runs. The final all-category run passed that
crashtest too: 14/15 files passed, with the same one constructor assertion failing.

[`manifest-character-data-ranges.yaml`](manifest-character-data-ranges.yaml)
adds the generated live-Range mutation matrices. Run it with
`--timeout-ms 60000`: upstream marks the setter matrix `timeout=long`, and the
default 10-second cap interrupted progressing work. With the longer bounded
budget, all six files and 5,400 assertions passed; the setter matrix completed
in 46 seconds. These older tests catch mutation exceptions, so they can pass
without an implemented method: always pair them with the direct mutation
manifest and native/in-page regressions, not use them alone as feature proof.

Both manifests are already covered by the default `dom` directory across all
runnable categories; no duplicate default entries are needed. Reftests cannot
establish DOMString identity or live Range positions. The local
[`character-data.html`](../manual/character-data.html) fixture additionally
checks real layout invalidation and literal-text measurement. Remaining limits
include synthetic-only comments/CDATA/processing instructions, MutationObserver
records, cross-Realm constructor semantics, and the full-layout invalidation
cost of attached text writes. This is not a whole-domain dashboard score.

[`manifest-html-fragments.yaml`](manifest-html-fragments.yaml) selects dynamic
HTML insertion, replacement, conversion, and retained-child checks. All selected
cases are already covered by the default `domparsing` directory or the explicit
HTML serialization allowlist, so this expansion needs no duplicate allowlist
entries. That directory also already includes its insertion crashtests; reftests
cannot establish JavaScript node identity or script inertness. HTML comments,
foreign/XML fragments, templates, and full table recovery remain limitations.
The 2026-09-06 focused comparison improved from 3/11 to 10/11 passing files
and 127/179 to 177/179 subtests, with no errors, timeouts, crashes, or
infrastructure failures. `innerhtml-08.html` remains expected-PASS but fails
its two HTML-root structure/comment checks. This is a focused score, not the
whole `domparsing` dashboard score.

`manifest-referrer.yaml` probes referrer-policy reflection and two network
prerequisite cases. The invalid-value and script-IDL tests are enabled in the
default allowlist. The XHR messaging helper currently requires working WPT
security-feature substitutions and Location; the detached-meta test requires
Fetch/Response (and one case needs `Document.parseHTMLUnsafe`). They remain
focused probes, not default coverage. Wire behavior is independently checked
by `zig build test-referrer`; reftests/crashtests cannot establish which Referer
header was sent.

The reftests in the table, replaced-sizing, SVG-image, and media-range
manifests below also run in the default [allowlist](manifest.yaml). Their
focused manifests remain useful for narrow iteration; they are no longer
the only way to exercise that coverage. The media-query harness and CSP
manifests still have the separate prerequisites described below.

For the bounded HTML table sizing work, run the unchanged upstream reftests
in `manifest-html-tables.yaml`:

```sh
python3 tests/wpt/run.py tests/wpt/manifest-html-tables.yaml --mode reftest \
  --jobs 1 --browser ./zig-out/bin/zibra --report /tmp/html-tables.json
```

This targets content-sized and percentage table/cell widths and `nowrap`,
including the live parser's implicit row groups, not spanning cells or
collapsed-border conformance.

For constrained image sizing, use `manifest-replaced-sizing.yaml` with the
same serial reftest command. It targets `max-width`, ratio transfer after
height constraints, and definite versus indefinite percentage heights,
including images inside anonymous blocks and inline ancestors. It does not
claim SVG sizing, grid spanning, or intrinsic-size keyword support.
The two GIF/XHTML-reference cases remain expected-PASS failures: the image
geometry has local assertions, but transparent GIF painting and CDATA styles
in navigated XHTML references remain unsupported. Do not count those local
geometry assertions as upstream reftest passes.

For media-query range and condition grammar, use
[`manifest-media-ranges.yaml`](manifest-media-ranges.yaml) with `--jobs 1`.
It includes unchanged range/negation reftests and the larger upstream
self-contained media-query suite. The latter additionally depends on
style-element `media` attributes, CSSOM serialization and iframe script APIs;
do not count its timeout as evidence of a parser hang. Pure evaluator and
live resize regressions cover range operands/boundaries independently of
those prerequisites. This chunk supports width, height, color and monochrome,
not all device features or media-value units/functions.
The current bounded run remains two reftest failures and one timeout. Both
test pages paint the intended green square, but the shared XHTML reference's
CDATA stylesheet does not paint its square. The harness case reaches harness
readiness without starting subtests. Keep the PASS expectations and report
these remaining prerequisites separately from local range/resize assertions.

`manifest-csp.yaml` tracks external-style CSP tests. The response-header URL
gate has deterministic coverage in `zig build test-csp`; these unchanged
upstream cases also require meta-delivered policies and violation events.
The wildcard case passes even without meta enforcement, while the deny case
still times out waiting for a violation event. Do not interpret that partial
result as full CSP conformance.

For static SVG image decoding, use `manifest-svg-images.yaml` with the same
reftest command. It compares SVG-backed `img` elements against CSS background
references. The shared resource covers XML declarations, CSS units, inline
paint styles, and `preserveAspectRatio="none"`. These pages also depend on float
layout, borders, and object/background positioning, so inspect mismatches before
attributing them to decoding. Decoder pixel and allocation-failure regressions
run independently with `zig build test-render -Dtest-filter=SVG`.
The same manifest also covers inline SVG encoded fill/stroke references and a
nested viewBox with CSS sizing/padding. Live cascade, resource refresh,
animation sampling and snapshot isolation have focused engine tests in that
SVG-filtered run; the manual live SVG page exercises their combined paint.

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
under the same process-group watchdog as upstream cases. It also checks live
body replacement/layout and title mutation in the document-accessor page.
Those local fixtures are protocol/engine regressions, not WPT conformance
claims.

The YAML file is the compatibility allowlist. Add supported directory prefixes
to `directories`, individual semantic cases to `tests`, individual visual
cases to `reftests`, crash cases to `crashtests`, and fetch/parse smoke tests to
`probes`; keep unsupported
areas out of execution and record only intentional expected deviations.

## Default capability coverage

The default allowlist includes bounded HTML, CSS, and SVG coverage alongside
the broad DOM/event directories. The 2026-09-06 expansion adds 63 cases:
19 testharness, 41 reftests, and 3 crashtests. This is a coverage baseline, not
a claim of complete support for these WPT domains.

The serial macOS ReleaseSafe baseline completed all 63 cases: 43 PASS and
20 FAIL, with no ERROR, TIMEOUT, CRASH, or INFRA results. By upstream directory,
HTML was 8/19 passing, CSS 21/29, and SVG 14/15. These are results for the
selected subset, not whole-domain scores. The local report is
`tests/wpt/results/capabilities-expanded-20260906.json`.

The document-accessor implementation additionally enables seven HTML
testharness cases for title normalization, empty-title creation, detached HTML
documents, direct text children, SVG titles, and inert XML title setters.
The paired XHTML cases remain outside this slice: top-level XML document
loading and namespace-aware XML parsing are separate prerequisites. These
accessor suites contain semantic harness tests, not visual/crash cases; no
new reftest or crashtest is implied by this API-only chunk.

The paired 18-case accessor run improved from 4 PASS / 14 FAIL to
15 PASS / 3 FAIL (41 to 101 passing subtests out of 115), with no timeouts,
crashes, or infrastructure failures. All 14 selected head/body/title cases
pass; the remaining failures are forms/images/scripts collection APIs.
Reports: `tests/wpt/results/document-accessors-before-20260906.json` and
`tests/wpt/results/document-accessors-after-20260906.json`.

| Area | Selected behavior |
| --- | --- |
| HTML | Document head/body/title and live collections; title text; nested-tag parsing; fragment serialization; table/cell sizing and nowrap. |
| CSS | Computed custom properties, substitution/cycles and fallback token handling; root-relative units and restyling; media ranges/negation; constrained image sizing. |
| SVG | Live root sizing; SVG-backed images; linear/radial gradient references; local use/symbol inheritance and selectors; nested viewBox/transforms; clipping; image href; dynamic viewBox repaint; filter inputs and empty shapes. |
| Process health | Static zero-size SVG geometry and malformed/whitespace custom-property fallbacks, without script-only prerequisite APIs. |

SVG image sizing and filters also have tests under `css/`; WPT directory
names do not map one-to-one to Zibra subsystems. The unchanged cases keep PASS
expectations, including semantic failures. Known GIF/XHTML-reference limitations
remain visible rather than being relabeled as passes.

The selection does not enable all of `html/`, `svg/`, or `css/`. SVG path
measurement/animated-value IDL, script-controlled SMIL seeking, cross-root use
references, masks/patterns/markers, and tests requiring unsupported automation
are not implied by the existing renderer. In particular, crash cases whose
setup aborts on an unavailable API cannot establish that their intended crash
condition was exercised.

The larger `css/css-variables/variable-cycles.html` harness is not selected:
its cases fail on missing window-global ID lookup before testing resolution.
Static cycle/dependent/fallback reftests cover that implemented capability
without the unrelated prerequisite.

To rerun just this expansion against an already built executable:

```sh
python3 tests/wpt/run.py tests/wpt/manifest.yaml --mode all --jobs 1 \
  --directory html --directory svg \
  --directory css/css-variables --directory css/css-values \
  --directory css/css-sizing --directory css/mediaqueries \
  --directory css/css-images --directory css/filter-effects \
  --browser ./zig-out/bin/zibra --report /tmp/wpt-capabilities.json
```

These filters select the expansion as of the date above; future allowlist
additions under those prefixes will also run. Manifest-runner unit tests guard
representative coverage and promotion of the focused reftests without requiring
an upstream checkout.

[`manifest-css-linear-gradients.yaml`](manifest-css-linear-gradients.yaml) covers
one background layer of ordinary/repeating linear gradients: four mixed-family
testharness files, nineteen paint references and the NaN-gradient crash case.
All 24 cases are newly enabled in the default allowlist. Radial/conic cases in
the shared syntax suites retain their upstream expectations; their failure does
not imply the corresponding linear assertion failed. The companion
`multiple-position-color-stop-linear-2.html` was reviewed but omitted because
reference discovery does not recognize its unquoted `rel=match` link. Its other
multiple-position reference is included. Gradient animation/WAAPI suites remain
outside this capability.

The final run improved from 9/24 to 19/24 files and from 352/2784 to 1071/2784
assertions, with 719 gained and none lost. All linear/repeating-linear syntax
assertions pass; the 1713 remaining assertions belong to radial/conic gradients.
Two paint references fail: `gradient-single-stop-001.html` paints the correct
solid color but exposes existing absolute static-position overlap with preceding
text; `normalization-linear-degenerate.html` expects the last stop where the
[Images 3 draft](https://drafts.csswg.org/css-images-3/#repeating-gradients)
specifies averaging a zero-length repetition. The implementation retains that
average. Expectations are unchanged. The remaining seventeen paint references
and the crash case pass without errors, timeouts or infrastructure failures.
Mixed-family passing references do not establish radial/conic support.

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
The default manifest selects the entire `css` directory, including failing
cases and features the engine does not implement yet. This replaces the former
individual CSS allowlist; newly discovered runnable CSS tests are selected
automatically. It is a compatibility measurement, not a passing gate. Manual
and other discovery-only categories still cannot execute in this runner.
Use focused manifests or `--directory css/css-color` for development iterations.
To collect the full CSS corpus with an already built browser:

```sh
python3 tests/wpt/run.py --directory css --jobs 1 --report /tmp/zibra-css-wpt.json --browser ./zig-out/bin/zibra
```

This can be a long run. Failures, timeouts, and infrastructure errors remain
visible in the report; no blanket CSS skip or expected-failure overrides are
applied. Existing dashboard reports do not change until a new run is collected.

`task wpt` runs that mixed-category
allowlist with `--full-suite`: directories outside the allowlist are not
executed, but remain in the report as `0/N` and mark its compatibility summary
as failing without failing the completed command. This keeps
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

The first audio-element pass has a small audio-only allowlist in
`manifest-audio.yaml`: constructor identity, volume, the empty constructor's
resource state, and hidden fallback-content reftests. Run it with the same
`--jobs 1 --browser ./zig-out/bin/zibra` options. It does not claim video,
streaming, autoplay/testdriver, or complete media-event conformance.

## Resumable batches with GNU Parallel

The normal interface is:

```sh
task wpt        # Start, or resume unfinished work.
# Press Ctrl+C to finish active batches and save progress.
task wpt        # Continue where you stopped.
task wpt-fresh  # Start over, preserving previous results.
```

GNU Parallel must be installed (`brew install parallel` on macOS). The task
builds Zibra, discovers the existing manifest selection, and generates batches
automatically. There is no extra test list, preparation command, run-directory
argument, or resume flag to remember. A completed run is followed by a new run
on the next invocation. Only one automatic run can be active at a time.

Ctrl+C stops dispatching and drains active batches before saving the aggregate
report. Leave the terminal open until the command finishes. Each batch runs up
to 25 cases serially, so draining can take time if a test reaches its timeout.
Workers are isolated from terminal interrupts; repeating Ctrl+C does not kill
them. Abrupt termination may repeat an unfinished batch on the next run.
Completed batches with failing CSS assertions remain completed work.

The current run is remembered under `tests/wpt/results`; its generated plan,
job log and per-batch results are internal run artifacts. Keep them together.
The dashboard report is written alongside the run directory when the run
finishes or pauses. `task wpt-fresh` preserves previous runs and changes which
one will resume. Existing monolithic runs cannot be imported into this log.

Before resuming, the coordinator checks the browser, selection manifest,
runner files, and WPT checkout metadata (including resources and new files).
If those changed, it explains that the run cannot resume and asks you to use
`task wpt-fresh`; it never silently combines different inputs. The checkout
check uses file size and modification time, not a full content hash of every
asset, so preserve the checkout while a run is paused. Reports remain readable
regardless of input changes. Builds and execution happen under the same lock.

GNU Parallel assigns the next pending batch to an available worker. Each batch
has its own Python process and WPT server, separating image comparison work
across CPU cores. Results are saved independently; the large aggregate is only
written when collecting. Completed collection exits 0 even when compatibility
tests fail; inspect the report summary.

Advanced users can still invoke `batch.py prepare`, `run`, or `collect`
directly for a separately managed run, custom batch sizes, or focused selection.
These lower-level commands are not required by `task wpt`.

### SSH workers

GNU Parallel also accepts remote workers through `--sshlogin` and `--workdir`:

```sh
task wpt WPT_JOBS=4 -- --sshlogin host-a,host-b --workdir /srv/zibra
```

Provision the repository, WPT checkout/server dependencies, Python, browser
runtime libraries, and the **same browser binary** on each host first. The
remote working directory must contain that checkout; the run directory and
browser paths must be repository-relative. SSH authentication and rsync must
already work. GNU Parallel transfers the generated plan with `--basefile` and
captures remote stdout/stderr back on the coordinator; no shared results
filesystem or manually copied test lists are required. `--jobs` applies per
host. The first version deliberately requires identical browser binary hashes,
so use workers with compatible OS/architecture and runtime libraries, rather
than combining different platform builds into one result.

Workers verify the browser and adapter hashes and selected WPT source hashes.
Keep the entire WPT checkout (including references/resources) identical and
unchanged across hosts: these checks do not hash every transitive resource.
A new build or adapter edit requires a new prepared run. Remote hosts and browser
dependencies are not installed automatically. Existing monolithic `task wpt`
runs cannot be adopted into this batch job log.

Scheduler semantics follow the [GNU Parallel manual](https://www.gnu.org/software/parallel/man.html).
`python3 -m unittest discover -s tests/wpt -p test_batch.py` checks batching,
collection, corruption handling, and build identity; when GNU Parallel is on
PATH it also executes local scheduling and resume integration tests. These tests
use fixture results and do not launch the browser. Remote execution needs an
explicit SSH-host integration check before relying on a new worker setup.
