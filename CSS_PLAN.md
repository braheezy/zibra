# CSS engine plan

Status: proposed direction; no library adoption or engine migration is implied
by this document. Library evaluation snapshot: 2026-09-06.

## Direction

Reuse pure-Zig CSS syntax and value-parsing libraries where they pass explicit
acceptance gates. Keep stylesheet ownership, CSSOM, selector matching, cascade,
computed values, invalidation, and rendering integration under Zibra's control.

The leading syntax candidate is **Terence CSS**. The independent
**csscolorparser-zig** library is a promising replacement for literal-color
parsing. Neither is a complete browser style engine. Library adoption and an
engine design plan are complementary, not competing approaches.

Migrate one boundary at a time. Preserve working page behavior while replacing
the foundations that make further compatibility work difficult. A parser
replacement must not become a prerequisite for every unrelated rendering fix.

This document describes future work. The
[architecture index](docs/architecture-and-lifetimes.md), especially the
[document and rendering contracts](docs/architecture/document-and-rendering.md),
remains authoritative for current ownership and invalidation behavior. Update
those domain documents when implementation changes a contract; do not use this
plan as a second source of current lifetime rules.

## Motivation and current baseline

Representative failures on Wikipedia, Google, GitHub, and ziglang.org show why
CSS work matters: missing styling, cramped or misplaced content, incorrect
responsive behavior, and oversized images can make a page unusable. These are
not all parsing problems. Diagnose the first broken pipeline stage for each
regression rather than assuming that a larger parser fixes layout or painting.

Zibra already has a substantial homegrown CSS implementation:

| Current area | Entry points | Architectural pressure |
| --- | --- | --- |
| Syntax and declarations | [css_syntax.zig](src/document/css_syntax.zig), [css_value_tokens.zig](src/document/css_value_tokens.zig), [css_parser.zig](src/document/css_parser.zig) | Character scanning and a limited value-token interface coexist with property validation, selector parsing, and rule processing. |
| Selectors | [selector.zig](src/document/selector.zig) | Existing combinators, attributes, state/structural selectors, `:not()`, and `:has()` need a foundation for further grammar and specificity support. |
| Cascade and computed style | [css_properties.zig](src/document/css_properties.zig), [style_application.zig](src/document/style_application.zig) | String-backed computed fields, per-rule declaration maps, and numeric priority offsets make richer semantics harder to represent. |
| Values | [custom_properties.zig](src/document/custom_properties.zig), [length.zig](src/document/length.zig), [color.zig](src/document/color.zig) | Existing variable substitution, root-relative lengths, and bounded math must survive migration; value coverage is still incomplete. |
| Conditional rules | [media_query.zig](src/document/media_query.zig), [css_parser.zig](src/document/css_parser.zig) | Media queries and keyframes have bounded support; viewport-dependent rules currently rebuild from source rather than retaining a general conditional rule tree. |
| JavaScript and rendering | [script runtime](src/script/runtime/css_style.js), [render subsystem](src/browser/render/) | CSSOM must ultimately expose real engine state; layout and paint need explicit computed/used-value contracts. |

Known gaps motivating the design include modern selector functions such as
`:is()` and `:where()`, at-rule semantics beyond the current media/keyframe
paths, a durable CSSOM rule model, more complete property grammars and colors,
and layout features that cannot be supplied by a syntax library.

Do not interpret skipped CSS WPT cases as either implemented support or measured
failures. The allowlist is a coverage selection, not a CSS conformance score.
Likewise, recognizing a property name or preserving an at-rule in an AST is not
proof that Zibra implements its semantics.

## Library evaluation

The dependency constraint is pure Zig. Native wrappers around Rust/C engines
are outside this plan. Evaluate embedded library APIs, not whether a project's
CLI can transform or print a stylesheet.

### Leading candidates

| Candidate | Proposed boundary | Evidence and limitations |
| --- | --- | --- |
| [nickshiro/terence-css](https://github.com/nickshiro/terence-css) | Syntax frontend behind a Zibra adapter | Structured tokens/AST, nested rules and declarations, source ranges, and recovery diagnostics. Declares Zig 0.16 and no dependencies. Very new; browser recovery and adversarial-input behavior need independent evaluation. |
| [sorairolake/csscolorparser-zig](https://github.com/sorairolake/csscolorparser-zig) | Literal-color parsing behind Zibra's color API | Pure Zig, Zig 0.16, no declared dependencies. Covers named colors, hex, RGB/HSL including modern forms, HWB, OKLab, and OKLCH. `lab()`, `lch()`, and `color()` are not implemented in the evaluated version. |

The evaluation ran these pinned revisions' own tests with local Zig 0.16.0,
`ReleaseSafe`, and serial build jobs in isolated temporary directories:

| Library revision | Package version | Result |
| --- | --- | --- |
| [Terence `92c73631ad4928051b7d8eee8a01c015aea3516b`](https://github.com/nickshiro/terence-css/tree/92c73631ad4928051b7d8eee8a01c015aea3516b) | 0.1.4 | 250/250 tests passed |
| [Color parser `4750318549a914cf6f1529d16e5f252888691e08`](https://github.com/sorairolake/csscolorparser-zig/tree/4750318549a914cf6f1529d16e5f252888691e08) | 0.2.0 | 86/86 tests passed |

These are upstream unit/integration results, not WPT results, a security audit,
or Zibra integration results. No dependencies were added during the evaluation.
Revalidate the exact revision and toolchain before adoption.

Terence owns its AST containers but borrows its input source. Its indexed AST
retains invalid input separately from usable syntax. An adapter must respect
those lifetimes and exclude recovered invalid nodes from executable rules.
Recursive block/function parsing did not reveal an explicit depth budget in
the inspected source; resource bounds are an adoption gate, not an assumed
property. See the pinned
[AST](https://github.com/nickshiro/terence-css/blob/92c73631ad4928051b7d8eee8a01c015aea3516b/src/ast.zig)
and
[parser](https://github.com/nickshiro/terence-css/blob/92c73631ad4928051b7d8eee8a01c015aea3516b/src/parser.zig).

The color library supplies literal values, not the browser context for
`currentColor`, custom properties, inheritance, or system colors. Preserve that
distinction at the adapter boundary. See its pinned
[README](https://github.com/sorairolake/csscolorparser-zig/blob/4750318549a914cf6f1529d16e5f252888691e08/README.md).

### Other candidates considered

- [chadwain/zss](https://github.com/chadwain/zss): relevant CSS syntax work and
  a broader partial engine. Retain as a fallback syntax candidate and reference;
  its broader scope is not a reason to replace Zibra's DOM or layout owners.
- [cztomsik/graffiti](https://github.com/cztomsik/graffiti): experimental
  DOM/CSSOM and rendering work with Node integration and an older toolchain.
  Not a straightforward standalone CSS frontend for this migration.
- [Matuyuhi/zig-css-engine](https://github.com/Matuyuhi/zig-css-engine): useful
  selector/flat-DOM optimization experiments, not a complete stylesheet,
  cascade, and computed-style implementation to adopt.
- [vyakymenko/zigcss](https://github.com/vyakymenko/zigcss): CSS/preprocessor
  compilation and transformation tooling. Syntax preservation is useful, but
  does not provide browser computed-value or rendering semantics; Terence is
  the more focused frontend candidate for an initial spike.
- [OrlovEvgeny/zigquery](https://github.com/OrlovEvgeny/zigquery): selector
  querying over its own HTML/DOM model. Possible reference material, not a
  justification to replace Zibra's DOM to gain selector support.

These assessments are a shortlist, not an exhaustive catalog or a claim that
the other projects cannot become useful. No local build results are claimed
for these alternatives.

## Proposed architecture

The responsibility boundaries are more important than final module names:

```text
Owned stylesheet source and base URL
  -> syntax frontend adapter (candidate: Terence)
  -> persistent rule/declaration store <-> CSSOM bindings
  -> conditional rule selection and selector matching
  -> cascade and specified values
  -> computed values (optional literal-color helper)
  -> layout-dependent used values
  -> paint
```

### 1. Syntax frontend

Provide explicit entry points for sheets, declaration lists, and component
values so linked/inline styles and JavaScript mutations share syntax rules.
Preserve source ranges, declaration order and duplicates, nested rule order,
escapes, and token boundaries. Do not flatten the syntax into a winning-property
map before property validity and cascade order can be decided correctly.

Keep third-party AST types behind an adapter. The library must not own DOM
nodes, networking, JavaScript wrappers, layout, or rendering threads. Do not
use a formatter round trip as the browser's parsing path. Generic acceptance
of syntax must not automatically make `CSS.supports()` return true.

### 2. Source-owning stylesheet and rule store

Design one explicit owner for source storage, AST/rule data, and stylesheet
metadata, including the base URL needed by relative resources. Retain nested
conditional rules and declaration order rather than only flattened active
rules. Reevaluating media conditions should eventually select from retained
rules without reparsing an otherwise unchanged sheet.

Define stable stylesheet/rule identity and retirement before exposing it to
CSSOM. JavaScript must read and mutate the same model used by style resolution,
not an independent approximation. Specify what happens to retained wrappers
after rule deletion, stylesheet replacement, and navigation; an index alone
must not accidentally identify a later rule after storage reuse.

Prepare a replacement generation before publication. Old borrowers retire
before old source storage; parse or allocation failure must not publish
half-built state. Respect existing owning-URL and navigation contracts rather
than shallow-copying resource owners. Import fetching, if implemented later,
must retain the existing network/security boundary.

### 3. Selectors and cascade

Separate selector grammar/matching from generic CSS syntax. Introduce
structured specificity and a documented cascade comparison rather than adding
more numeric offsets. Represent origin, importance, layer ordering, inline
style treatment, specificity, and source order explicitly as they are
implemented. Account for the different ordering of important origins/layers;
one ascending numeric layer order is not sufficient.

Add `:is()` and `:where()` with their specified list handling and specificity.
Keep ordinary invalid selector-list behavior distinct from forgiving lists.
Existing `:has()` cache and mutation invalidation rules remain in force.

Treat `@supports`, `@layer`, nesting, and cascade-wide keywords as separately
testable semantic capabilities. An AST that retains them does not execute
them. Support queries must use actual supported selector/property grammars,
not just successful tokenization.

### 4. Property grammar and computed values

Extend the property registry toward a shared definition of initial value,
inheritance, grammar, shorthand expansion, computed-value conversion,
serialization, and invalidation impact. Introduce typed values by property
family; do not require an all-at-once conversion of every style consumer.

Keep specified, computed, and used values distinct. Preserve symbolic
percentages and math until their required basis exists. Resolve font-relative
and viewport-dependent units with an explicit context, including the existing
special root-font rules. Do not silently turn an indefinite basis into zero.

Retain custom properties as token sequences until substitution. Preserve the
existing fallback/cycle/expansion limits, pending shorthand behavior, and
invalid-at-computed-value handling: a winning declaration made invalid by
substitution must not revive an earlier losing declaration.

For colors, use a helper only for supported literals. Define the conversion
boundary into Zibra's paint representation, alpha handling, and gamut policy;
parsing OKLCH is not a claim of a wide-gamut rendering pipeline. Invalid input
must not overwrite an earlier valid declaration during ordinary parsing.

### 5. Invalidation and rendering handoff

Specify which dependencies trigger selector rematching, computed-style work,
layout, or paint. Cover stylesheet/CSSOM mutation, attributes/classes, inherited
values, variables, root fonts, viewport conditions, and interaction state.

Preserve stable `ProtectedField` publishers, structural-mutation rebinding,
source-buffer retirement order, and the existing Frame style/layout/paint
phase separation. New types must not introduce pointers that outlive their
document or stylesheet generation. Layout and raster must not retain borrowed
third-party parser data accidentally.

Flex/grid sizing remains a distinct downstream workstream. Improved CSS
plumbing should make used-value inputs clearer, but migrating syntax does not
implement intrinsic sizing, track placement, or other layout algorithms.

## Phased implementation and acceptance gates

### Phase 0: bounded frontend acceptance spike

1. Pin Terence and document its public API, license, toolchain, dependencies,
   source lifetime, and upstream-update policy. Keep the experiment isolated
   from the production path until the decision is made.
2. Assemble deterministic reduced fixtures from representative page failures
   and selected real stylesheet inputs. Include invalid declarations, duplicate
   fallbacks, escapes, comments, URLs, nested functions/rules, and EOF recovery.
3. Compare applicable behavior with unchanged targeted CSS Syntax WPT cases.
   Where a WPT requires unsupported CSSOM/DOM infrastructure, record the
   blocker and add direct parser coverage; do not call that an upstream pass.
4. Test source retirement, failed allocations and cleanup with a reclaiming
   allocator. Bound source size, tokens/nodes, nesting, and recovery work;
   deeply nested or malformed input must not cause uncontrolled recursion or
   nontermination. Process watchdogs complement, not replace, engine limits.
5. Produce an adopt/adapt/reject decision with remaining gaps. If rejected,
   evaluate zss syntax components or a Zibra-owned frontend behind the same
   boundary; do not abandon the engine architecture because one library fails.

Exit gate: an evidence-backed frontend decision, a reproducible test corpus,
and a concrete owner/adapter design. Passing the library's own tests alone is
insufficient.

### Phase 1: independent color-value improvement

Evaluate the color helper behind the existing color API. Add literal parsing,
invalid-value fallback, alpha/conversion tests, and a page-level color
regression. Cover variable-substituted literals without moving `var()` or
contextual color semantics into the library.

Exit gate: existing supported colors remain correct, newly supported literals
have focused upstream and engine coverage, and serialization/conversion
limitations are explicit. This phase does not depend on adopting Terence.

### Phase 2: syntax and stylesheet ownership migration

Introduce the accepted frontend adapter and source-owning rule store, then
route stylesheet and inline declaration parsing through it in bounded steps.
Keep existing selector, property, and rendering consumers behind transitional
adapters where needed. Preserve declaration order and recovery behavior.

Add replacement/OOM/teardown regressions before retiring old storage paths.
Verify both interactive Frame loading and isolated inspection consumers.
Keep compatibility scaffolding temporary with an explicit removal condition;
avoid two permanent, independently evolving CSS interpretations.

Exit gate: existing supported pages and pipeline goldens remain correct,
dynamic replacement is lifetime-safe, and replaced parser paths can be removed.

### Phase 3: modern rule semantics and live CSSOM

Build structured specificity/cascade precedence and modern selector functions
on the retained rule model. Add conditional/layer/nesting semantics in separate
chunks with explicit scope and focused tests. Bind supported CSSOM reads and
mutations to real stylesheet/rule identities, including their invalidation and
retirement behavior.

Exit gate for each chunk: visible page benefit or a demonstrated dependency
unblock, unchanged targeted WPT evidence, and mutation/lifetime coverage. A
complete CSSOM or every modern at-rule is not required to ship the first chunk.

### Phase 4: typed computed values and downstream layout work

Move property families to typed values and shared registry metadata while
preserving existing consumers through narrow adapters. Prioritize families
implicated by representative failures, such as sizing, fonts, and colors.
Extend units/math only with the necessary resolution and invalidation context.

Then select concrete flex/grid or other used-value deficiencies from page
failures. Verify their geometry independently of parser correctness.

Exit gate for each family: declaration validity, cascade, computation,
serialization where exposed, used-value behavior, and invalidation all have
coverage. Remove obsolete conversion paths once consumers migrate.

## Verification and WPT policy

Follow the [testing guide](docs/testing.md#compatibility-driven-development).
Each implementation chunk must record its motivating failure, bounded
baseline, engine owner, exact checks, and remaining limitations.

- Add focused unit tests, using reclaiming allocators for ownership paths.
- Select relevant unchanged upstream tests from CSS Syntax, Selectors,
  Cascade, Conditional Rules, Variables, Values, Color, and CSSOM as applicable.
  These are candidate areas, not a blanket instruction to enable all of CSS.
- Review and expand the [WPT manifest](tests/wpt/manifest.yaml) when a feature
  becomes runnable. Enable focused testharness, reftest, and crashtest cases as
  appropriate; record unmet adapter/prerequisite requirements instead of
  silently omitting coverage. Failed assertions are evidence, not a reason to
  hide supported runnable cases or rewrite upstream expectations.
- Add style/layout/display-list regressions for user-visible behavior and
  native screenshot checks for final pixels. Test relevant narrow and wide
  viewports, not only a single desktop size.
- Put interactive fixtures in `tests/manual/` with a `How to verify` comment
  and an entry in its [catalog](tests/manual/README.md).
- During iteration, use the relevant `test-document`, `test-render`,
  `test-script`, or `test-browser` step. Before handoff, expand to
  `test-pipeline`, the relevant broader/aggregate checks, and native visual
  checks according to risk. Documentation edits use `test-docs`.
- Run native jobs serially with a process-group watchdog and complete cleanup
  and reaping. Use the WPT runner's supervision for upstream cases; leave no
  orphan browser, test, build, or server processes.
- Report semantic failures, unsupported prerequisites, crashes, timeouts, and
  harness failures separately. Full WPT sweeps are periodic health checks,
  not the default edit loop; performance scores come after correctness gates.

## Deferred scope and open decisions

This plan does not promise complete CSS conformance, a replacement layout
engine, or automatic visual parity from library adoption. Dedicated designs
remain necessary for capabilities such as imported-sheet loading, web fonts,
nonempty generated content, container queries, broader animation semantics,
and advanced flex/grid layout when selected as concrete work.

Resolve these questions at the phase that needs them, before publishing a new
contract:

- Can Terence meet browser recovery/resource requirements without an extensive
  permanent fork, and what local adaptation/upstream maintenance is acceptable?
- Which source/AST representation and stylesheet/rule handles provide stable
  CSSOM identity without retaining entire obsolete document generations?
- What bounded resource limits and failure behavior should all CSS entry
  points share, including JavaScript mutation and custom-property expansion?
- Which typed-value family offers the largest demonstrated page benefit, and
  how will its existing serialization and `ProtectedField` consumers migrate?
- Which relative-resource, color-conversion, and conditional-rule semantics
  are required by the first adopted feature rather than merely representable?

The next implementation task is Phase 0, with Phase 1 available independently.
Update this plan with the adoption decision and completed gates as evidence
arrives; do not turn proposals or upstream test counts into support claims.
