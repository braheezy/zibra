# CSS frontend acceptance

Decision: **adapt Terence; do not switch production parsing yet**. The
[CSS plan](../CSS_PLAN.md) now has a source-owning syntax adapter and an opt-in
inspection integration, updated on 2026-09-08. Terence-derived rules and
inline declarations feed the real style/layout/display-list pipeline. Browser
navigation, screenshot and WPT adapters still use the legacy frontend; this
does not claim an interactive browser compatibility increase.

## Dependency and integration

The existing [package pin](../build.zig.zon) selects Terence 0.1.4,
[`92c73631ad4928051b7d8eee8a01c015aea3516b`](https://github.com/nickshiro/terence-css/tree/92c73631ad4928051b7d8eee8a01c015aea3516b).
Its license is MIT, copyright 2026 Nick Asmodeus; its package requires Zig
0.16.0 and declares no dependencies. This implementation uses Zig 0.16.0.

The public module exports `parseStylesheet` and `Ast`. `Ast` additionally
provides `parseBlockContents` and `parseComponentValues`. The AST owns its
tokens, nodes, child-index lists and parser diagnostics, while borrowing the
entire source. Comments remain token trivia; declaration lists and nested
rules remain ordered. Declaration priority has its own node tag. Invalid
recovery nodes are retained alongside usable syntax. No formatter is involved.

The public module does not expose `Tokenizer`. The build copies the exact
pinned `ast.zig`, `parser.zig`, `tokenizer.zig` and MIT license into a generated
cache module, with a two-export root. This avoids compiling the same upstream
file as two different Zig modules. These copies are **unmodified**; they are
neither a checked-in vendor fork nor a second parser implementation. Remove
this build bridge when the upstream public module exports the tokenizer.
The executable and all unit-test roots import the experimental backend;
inspection selects it explicitly with `--css-parser=terence`.

Dependency updates must remain pinned, re-run this corpus and upstream tests,
and review parser progress, recursion, token/node ranges, diagnostics and OOM
cleanup. Never edit `zig-pkg` or generated cache files to carry a fix. A local
fork should publish a new pinned package only after these gates pass; keep its
changes limited to upstreamable frontend contracts.

## Implemented owner and boundary

[`css_frontend.zig`](../src/document/css_frontend.zig) owns a duplicated source,
optional duplicated serialized base URL, AST and diagnostics. Its heap holder
keeps the allocation context stable when the outer owner moves. No owning
network URL, DOM pointer, render pointer or JavaScript wrapper enters this API.

The three entry modes share one source owner: stylesheet, declaration block
contents, and component values. Views expose Zibra node kinds, byte ranges,
generation-bound node IDs, ordered child iterators and declaration metadata.
Syntax values retain their original spelling, including escapes, comments,
invalid property fallback candidates and `var()`. The syntax owner constructs
no property map or semantic serialization. A separate Zibra normalization and
declaration boundary now feeds supported style consumers; raw ranges still
cannot be used as CSSOM serialization.

`declaration` filters recovered invalid nodes, bad strings/URLs, and unmatched
closing tokens in values. It does not validate a property grammar, execute
at-rules, match selectors or make `CSS.supports()` succeed. EOF recovery
diagnostics do not automatically invalidate a usable token. Tokenizer
diagnostics, discarded by upstream's AST construction, are retained separately
from parser diagnostics.

Construction stages all owners before returning. The offline `replace` helper
keeps the previous generation intact on any failure; it requires all external
borrowers to be retired before success. Future live consumers must instead
stage `parse`, invalidate their borrowers at the existing publication boundary,
then move and retire owners explicitly. These indices are not CSSOM identities.
The authoritative lifetime contract is in
[document and rendering](architecture/document-and-rendering.md#experimental-css-syntax-owner).

## Experimental interop

[`css_declarations.zig`](../src/document/css_declarations.zig) now owns the
property validation, shorthand expansion and declaration precedence previously
embedded in `css_parser.zig`. The legacy scanner and retained frontend use this
same grammar. The retained path supplies declaration-local `!important`
explicitly and applies ordered declarations before dropping invalid fallback
candidates or expanding shorthands.

[`css_stylesheet.zig`](../src/document/css_stylesheet.zig) owns source, syntax,
normalized strings, translated selectors, keyframes and nested media
conditions. It reuses Zibra's selector parser, media evaluator and cascade.
Rule selection reevaluates retained conditions and clones executable owners;
it does not reparse syntax, selectors or property values. Source provenance
and cascade origin remain distinct. Unknown at-rules and nested style rules
are retained syntax with no added `@supports`, layer, import or nesting
semantics. There are no new live CSSOM identities or mutation bindings.

Malformed/unsupported selectors discard their entire rule, but selector
admission limits reject the stylesheet generation explicitly. Lists are
bounded to 256 members, 64 KiB and 64 nested brackets/functions by Zibra's
selector entry point; these resource errors also preserve an installed Page
generation when replacement fails.

[`css_normalize.zig`](../src/document/css_normalize.zig) bridges identifier,
function, hash and dimension-unit spellings into existing property consumers
while preserving token boundaries. It supplies implicit EOF block/function
closing where supported. String/URL payload escapes remain authored; full
string/URL EOF repair and CSSOM serialization are still missing. This bounded
bridge does not make every syntactically valid value supported.

[`css_inline_styles.zig`](../src/document/css_inline_styles.zig) caches owned
declaration blocks for current authored inline attributes. The style pass
borrows those maps through `InlineStyleProvider`, using the same cascade and
Element-owned computed strings as ordinary rules. A cache miss is explicit;
there is no hidden legacy fallback. Inline mutation must rebuild this cache
before styling; this is an inspection generation, not a live CSSOM cache.

[`inspection.Page`](../src/document/inspection.zig) combines these owners with
the styled DOM. Media reselection and stylesheet replacement stage all
fallible owners before invalidating and publishing. Successful publication
installs dirty style state; `restyle` is a separate fallible phase and must
complete before layout/paint. Layout/display consumers must retire before
either mutation API is called. The authoritative lifetime document linked
above defines retirement and failure behavior in detail.

The CLI accepts `--css-parser=legacy|terence` only with `--dump-style`,
`--dump-layout`, or `--dump-display-list`. Legacy remains the default. For
example:

```sh
zig build run -- --dump-layout --css-parser=terence --viewport=800x600 \
  file://"$PWD/tests/pipeline/css-terence-recovery.html"
```

The [parity fixture](../tests/pipeline/css-terence-parity.html) covers ordinary
rules, escaped property names, duplicate fallbacks, `!important`, shorthands,
variables, inline attributes and nested media at 320x300 and 800x600. The
[recovery fixture](../tests/pipeline/css-terence-recovery.html) expects two
120px green bars: a declaration after an unknown nested at-rule, and a final
rule whose missing closing brace is repaired at EOF. The legacy parser skips
the first width declaration and drops the final rule. Escaped normal property
names already worked in legacy and are parity coverage, not a new benefit.

All Terence package sources remain unchanged. This integration establishes a
reviewable Zibra path while upstream parser hardening remains a separate gate.

## Resource bounds and adoption blockers

[`css_frontend_limits.zig`](../src/document/css_frontend_limits.zig) tokenizes
without allocation before calling the recursive parser. It enforces:

| Resource | Default | Enforcement |
| --- | --- | --- |
| Source | 1 MiB | Before copying/tokenizing; also protects upstream u32 offsets |
| Tokens | 32,768 including trivia and EOF | Preflight, then exact AST count |
| Nesting | 64 | Fixed delimiter stack before recursion; callers can only lower its ceiling |
| Live allocation | 16 MiB | All source, provenance, AST and diagnostic allocations through a heap-stable budget; excludes its fixed holder |
| Retained nodes | 131,072 | Exact postparse count; allocation remains capped during construction |
| Recovery admission charge | 67,108,864 | Overflow-checked `4*T*(B+T)` for sheets/declarations, `4*(B+T)` for component values |

`B` is source bytes and `T` preflight tokens. These are experimental admission
limits, **not production browser budgets**. The deliberately conservative
recovery charge rejects some ordinary large stylesheets. It bounds admitted
input for this pinned implementation; it is not a native instruction counter
and is not a substitute for reviewing parser progress when updating upstream.
Budget failures and allocator OOM are separate errors; neither silently falls
back to the old parser.

The retained Sheet and inline DeclarationBlock apply the same allocation
ceiling to their combined syntax and semantic storage, using a heap-stable
outer budget. Selected executable containers use the caller's allocator;
they remain subject to ordinary staging/OOM cleanup rather than this per-sheet
retention cap. These limits do not make large real-world sheets accepted.

Required changes before production adoption:

1. Add native limits/fuel to Terence's parsing API and node/token construction,
   including both unicode-range passes and speculative parsing. Its current
   recursive functions have no depth budget. Node count should be enforced
   during construction, not only against the retained tree.
2. Bound or remove repeated suffix scanning in `consumeBlockContents`:
   `consumeDeclaration(true)` can consume a bad declaration to the end of the
   enclosing block before restoring and parsing just one qualified rule.
   `@media all { .a{} .b{} .c{} ... }` repeats this scan for successive rules.
   Valid selector preludes containing colons need coverage too. The admission
   charge contains this behavior in the spike, but is too restrictive for a
   general browser frontend.
3. Export the tokenizer and retain lexical diagnostics in the public API.
   Specify browser handling of bad value tokens separately from formatter
   preservation; the adapter currently performs that filtering.
4. Complete decoded token values and serialization before adopting live
   style/CSSOM consumers. The inspection normalization bridge covers supported
   identifiers/units and some EOF recovery, but not full string/URL repair,
   CSSOM serialization or every custom-property token form. Source preservation
   alone is insufficient.

These findings support a small frontend fork/upstream contribution, not
abandoning the selected architecture. Color work remains independent.

## Corpus and verification

Run the acceptance tests with:

```sh
zig build test-document -Dtest-filter='CSS frontend' -j1 --summary all
```

Use the process-group watchdog required by the [testing guide](testing.md)
around native jobs. The tests live in
[`src/tests/css_frontend.zig`](../src/tests/css_frontend.zig):

- `page-reductions.css` is an authored reduction of the page stylesheet shapes
  motivating the plan: media-wrapped infobox sizing, conditional search grids,
  repository toolbar nesting, escaped selectors and documentation font sources.
  It is not a captured website sheet or proof those pages now render correctly.
- `recovery.css` covers invalid declarations, bad URLs/strings, empty custom
  values, unknown rules, delimiters in strings, and unclosed functions/blocks.
- The actual checked-in `browser.css` supplies a real production stylesheet.
- WPT-derived syntax inputs cover escaped EOF, unclosed URL tokens, at-rules
  preceding declarations, and 60,000 unclosed parentheses.
- Reclaiming-allocator tests retire and overwrite caller inputs, move owners,
  replace generations, inject every allocation failure across all entry modes,
  and verify rollback and memory accounting. A fixed-seed malformed corpus
  exercises 300 inputs in all three entry modes with range checks.

The interop adds retained-sheet and inline declaration owner regressions next
to their modules, alongside the shared declaration grammar tests. The
[pipeline manifest](../tests/pipeline/manifest.zig) mirrors existing cases
under Terence against the original goldens, runs both parsers against shared
narrow/wide parity goldens, and adds Terence recovery goldens. The integration
tests also check real layout geometry, display colors and software pixels
across responsive reselection and source replacement, retiring render
borrowers before each publication.

The merge-review regressions additionally exercise every allocation failure
during restyle, including inherited/root-relative dependencies and newly
generated boxes. After retry, separate ancestor-only changes verify inherited
color, custom-property and root-relative subscriptions. Core graph tests cover
failure before table/edge publication and successful re-registration. Another
210-case malformed corpus reaches the complete Sheet/select/inline adapter,
in addition to the syntax-only corpus. Selector tests verify the 256/257-member
boundary and rollback when a replacement exceeds it.

## Interop validation results (2026-09-08)

- `zig build verify -Doptimize=ReleaseSafe -j1 --summary failures`: the initial
  interop run **passed**. The post-fix run passed all non-unit steps, including
  focused-root compilations, 45 pipeline captures, DOM dumps, local WPT protocol
  fixtures, CSP/referrer transport checks, server and WPT-runner tests,
  formatting and documentation links. Its unified suite passed **807/808**;
  `removeChild detaches a subtree and preserves handles across reattachment`
  failed without an assertion location in the ReleaseSafe diagnostics.
- A direct rerun of the same unified ReleaseSafe executable with the same seed
  (`0x3c8f4b69`) passed **808/808**. The detach/reattach test also passed alone
  under Debug. This leaves an observed intermittent test failure with its cause
  unresolved; the post-fix aggregate is not recorded as a clean pass.
- `zig build test-document -j1 --summary all`: **218/218 passed** after the
  merge-review fixes, with reclaiming Debug allocators. Coverage includes every
  allocation failure during replacement, reselection and full restyle;
  computed-string lifetime after source retirement; selector admission and
  rollback; and dependency updates after retrying a failed style pass.
- `zig build test-document test-pipeline test-docs test-format
  -Doptimize=ReleaseSafe -j1 --summary all`: **all 45 pipeline captures passed**,
  including the 15 original cases repeated under Terence against unchanged
  goldens. This earlier run passed 207 document tests; the Debug run above
  includes the final token-boundary and merge-review regressions.
- `zig build test-render -Doptimize=ReleaseSafe
  '-Dtest-filter=Terence inspection' -j1 --summary all`: **1/1 passed**, checking
  geometry, paint bounds/colors and actual software pixels for a 40x20 green
  box, an 80x30 blue box after media reselection, and a 55x25 red box after
  stylesheet replacement.
- Direct legacy/Terence captures match exactly for the parity fixture at both
  viewports. The recovery fixture produces two 120px green bars under Terence;
  legacy produces a 24px green bar and a 24px red bar. Only new fixture goldens
  were added; existing goldens were not regenerated.
- The six-case interop WPT baseline completed: **4 passed, 2 failed** and
  **9/9 testharness assertions passed**, with no crashes, errors, timeouts or
  infrastructure failures. Both failures are the ordinary/media EOF reftests
  (`eof-001.xht`, `eof-004.xht`). These are legacy Browser results, not Terence
  conformance claims. The default allowlist and upstream expectations remain
  unchanged for the reasons below.
- CLI checks reject unknown/duplicate parser choices and use outside the
  supported style/layout/display inspection modes. The 257-selector review
  reproducer now exits 1 with `SelectorLimitExceeded` under Terence; legacy
  still exits 0 and produces the expected 123px width.
- `zig build test-screenshot -Doptimize=ReleaseSafe -j1 --summary failures`:
  SVG inline/image goldens passed, then the existing `native-screenshot`
  mismatch reproduced exactly: **22,361 differing pixels**, maximum channel
  delta 255, first difference at (30, 85). This matches the Phase-0 baseline
  below, and the page pixels match the retained pre-fix capture exactly. Later
  serialized screenshot cases did not run through this step; no PNG goldens
  were changed. The Terence geometry/paint/pixel regression above passed
  separately.
- All nine skipped screenshot fixtures were then run independently, serially
  with the same comparator: view-source timed out after 30 seconds; scrollbar,
  emoji, alternate-text-direction, centered-title, superscript, soft-hyphens,
  small-caps and preformatted differed from their existing goldens. Running the
  retained pre-fix executable from this branch reproduced the timeout and
  produced identical page pixels for all eight captures. Across all 12 native
  fixtures there are **2 golden passes, 9 golden mismatches and 1 timeout**;
  these failures predate the merge-review fixes. This comparison does not
  establish a main-branch baseline. Linux CI remains unverified locally.

## Upstream coverage review

[`manifest-css-frontend.yaml`](../tests/wpt/manifest-css-frontend.yaml) is a
bounded **existing-engine baseline**, not an adapter conformance test. Run the
unchanged upstream cases through the normal WPT supervisor:

```sh
python3 tests/wpt/run.py tests/wpt/manifest-css-frontend.yaml --mode all \
  --jobs 1 --browser ./zig-out/bin/zibra --report /tmp/css-frontend-wpt.json
```

| Selected case | Pipeline and prerequisite |
| --- | --- |
| `css/css-syntax/escaped-eof.html` | Selector validation and live CSSOM normalized value serialization |
| `css/css-syntax/unclosed-url-at-eof.html` | Inline CSSStyleDeclaration value normalization |
| `css/css-syntax/at-rule-in-declaration-list.html` | Live stylesheet insert/delete and nested rule declaration views |
| `css/css-syntax/missing-semicolon.html` | Linked-sheet recovery and final pixels; reftest |
| `css/css-syntax/crashtests/unclosed-open-brackets.html` | Deep inline syntax through script; crashtest |

Also reviewed `input-preprocessing.html` and `invalid-nested-rules.html`:
their exposed selector mutation/serialization and nested CSSOM requirements
belong to later phases. Direct source/AST assertions are not upstream passes.
The new [interop manifest](../tests/wpt/manifest-css-interop.yaml) selects six
unchanged cases closer to this integration:

| Category | Selected coverage |
| --- | --- |
| Testharness | `css/css-syntax/declarations-trim-whitespace.html`: computed custom values and importance trimming without stylesheet CSSOM |
| Reftest | `css/css-syntax/missing-semicolon.html`, `css/CSS2/syntax/escaped-ident-char-001.xht`, `eof-001.xht`, `eof-004.xht`: ordinary declarations, escaped names, ordinary/media EOF recovery |
| Crashtest | `css/css-syntax/crashtests/atrule-with-escape-character.html`: static nested at-rule syntax without a mutation API prerequisite |

The normal runner's `--list` resolves all six categories/paths. No upstream
expectations were changed. The old CSS2 `declarations-009.xht` was reviewed but
excluded: its historical nested-at-rule treatment expects a following
declaration to be discarded, unlike the modern CSS Syntax harness case. The
`at-rule-013.xht` case additionally requires the separate XHTML CDATA stylesheet
path. The existing media manifest likewise retains its documented CSSOM and
reference prerequisites.

The default [allowlist](../tests/wpt/manifest.yaml) remains unchanged because
WPT's native testharness, screenshot and crash adapters cannot exercise the
experimental inspection switch. These focused manifests currently measure the
legacy engine; AST assertions and CLI dumps are not upstream passes. Promote
bounded cases when production parser/CSSOM capabilities reach those adapters,
including failures in implemented behavior and all applicable categories.
The merge-review fixes preserve allocation-failure recovery and explicit
adapter resource-limit errors. These internal contracts add no WPT-exposed
capability, so their exhaustive local regressions do not require further
allowlist additions.

## Phase-0 validation results (2026-09-07)

- `zig build test-document test-pipeline test-docs test-format -j1 --summary all`:
  **185/185 document tests passed**, including all 15 frontend acceptance tests;
  all pipeline goldens, formatting and local documentation links passed.
- The pinned upstream checkout's
  `zig build test -Doptimize=ReleaseSafe -j1 --summary all`: **250/250 passed**.
  This revalidates the original library assessment; it is not a WPT result.
- The five-case unchanged WPT baseline completed: **3 passed, 2 failed**;
  testharness assertions **2/13 passed, 11 failed**. No crashes, errors,
  timeouts, watchdog expirations or infrastructure failures were reported.
  The unclosed-URL equality test, missing-semicolon reftest (zero differing
  pixels at 800x600), and deep-input crashtest passed. The URL equality result
  alone does not establish a full normalized-value/serialization contract.
- `escaped-eof.html` failed one numeric-hash selector validation assertion;
  its four stylesheet-value assertions failed accessing missing CSSOM objects.
  All six `at-rule-in-declaration-list.html` assertions failed first because
  the `test_sheet` Window named property was undefined. They did not reach the
  at-rule parser. The fixture also requires the live CSSOM operations listed
  above once that first prerequisite is implemented. Expectations remain PASS.
- `zig build verify -j1 --summary all` was **stopped, not passed**, during the
  prolonged Debug unified JavaScript suite. Process samples showed progress
  through collector-thread lifetime, HTML fragment and same-origin proxy tests,
  dominated by runtime initialization/Debug allocator work. No CSS frontend
  failure was observed. Its process group was terminated and reaped before
  subsequent native jobs; the explicit document/pipeline checks above completed
  independently. The full unified aggregate remains to be completed.
- `zig build test-screenshot test-docs -j1 --summary all`: the `svg-inline`
  and `svg-images` comparisons passed; `native-screenshot.html` failed its
  existing golden comparison with **22,361 differing page pixels**, maximum
  channel delta 255, first difference at (30, 85). Visual inspection showed
  different text metrics/content height in the old golden and current capture.
  The serial suite did not run the remaining captures after that failure.
  No golden was changed, and this experimental backend is not linked into the
  browser executable. Documentation links passed again.

The local worktree's WPT checkout was empty, so the baseline reused the existing
checkout at `/Users/braheezy/code/zibra/tests/wpt/upstream` by setting the runner's
`UPSTREAM` constant in a temporary launcher. Test files and expectations were
unchanged; all cases used the normal runner's serial server/browser supervision.
The raw report was written to `/private/tmp/zibra-css-frontend-wpt.json`.

These results predate the inspection integration described above. They remain
the Phase-0 baseline, not verification of the new owners or pipeline path.
Interactive adoption and manual browsing verification remain Phase-2 work.
