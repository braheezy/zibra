# CSS engine plan

Decision: Zibra owns CSS syntax and browser semantics directly. The experimental
Terence dependency and alternate inspection backend have been removed. Work
continues from the current native implementation, preserving the shared
property grammar, selector checks, source provenance and invalidation fixes.
The [retirement record](docs/css-frontend-acceptance.md) distinguishes retained
work from the removed experiment and records known verification baselines.

## Current responsibilities

| Owner | Responsibility |
| --- | --- |
| [css_parser.zig](src/document/css_parser.zig) | Semantic rule compilation, bounded selector parsing, media/keyframe evaluation and executable rule types |
| [css_rule_syntax.zig](src/document/css_rule_syntax.zig) | Borrowed structural rule/declaration iterators, source order and EOF recovery |
| [css_tokenizer.zig](src/document/css_tokenizer.zig) | Borrowed lexical tokens, source decoding, numeric identity and EOF state |
| [css_syntax.zig](src/document/css_syntax.zig) | Structural delimiters over the shared token stream |
| [css_values.zig](src/document/css_values.zig) | Component validation, normalization and primitive serialization |
| [css_position.zig](src/document/css_position.zig) | Single-layer position grammar, specified axis serialization and signed used offsets |
| [css_declarations.zig](src/document/css_declarations.zig) | Shared property validation, shorthand expansion and declaration precedence |
| [css_declaration_block.zig](src/document/css_declaration_block.zig) | Owned ordered inline declarations, CSSOM edits, queries and serialization |
| [css_stylesheet.zig](src/document/css_stylesheet.zig) | Inspection-owned source and provenance; native parsing into borrowing selections |
| [selector.zig](src/document/selector.zig) | Selector ownership, logical lists, matching and specificity |
| [css_cascade.zig](src/document/css_cascade.zig) | Independent origin/importance, inline attachment, specificity and source-order keys |
| [css_anb.zig](src/document/css_anb.zig) | Shared token-based An+B admission and matching |
| [style_application.zig](src/document/style_application.zig) | Cascade, inheritance, computed values, animation updates and invalidation |
| [css_properties.zig](src/document/css_properties.zig) | Computed longhand registry, defaults and primitive serialization metadata |
| [custom_properties.zig](src/document/custom_properties.zig) | Variable environments, substitution, cycles and expansion limits |
| [length.zig](src/document/length.zig), [color.zig](src/document/color.zig) | Supported value grammars and conversions |
| [CSS style bindings](src/script/css_style_bindings.zig) and [runtime](src/script/runtime/css_style.js) | Handle-based native inline-style access and JavaScript conversions |

The [document and rendering contract](docs/architecture/document-and-rendering.md)
is authoritative for ownership and invalidation. This plan describes future
work rather than defining a second lifetime contract.

## Architecture review and first implementation

The engine already has useful boundaries: property/shorthand validation,
selector matching, computed style/invalidation, media environments and rendering
are separate owners. Source generations and computed strings have explicit
lifetimes, including allocation-failure coverage for replacement and restyling.
Keep those contracts while expanding CSS; a directory rename is not the missing
foundation.

The main gaps found in this review are:

- Structural rule recovery was mixed into selector/property parsing. Scanners
  only tracked parentheses, unknown blocks could consume later declarations,
  and unterminated final rules/media blocks were discarded.
- Executable declaration maps discard authored order and duplicates. They are
  useful for the current cascade but cannot also serve as a CSSOM rule model.
- Browser Frame generations and inspection Sheet selections share native
  parsing but retain sources through different owners. `Sheet` is currently
  inspection-only; moving it into the browser requires a staged ownership change.
- The JavaScript inline-style view had an independent declaration scanner.
  The second slice below removes it and shares native declaration storage;
  complete lexical tokenization and shared value normalization are now implemented
  (see the value-layer slice below); additional property grammars remain.
- Cascade precedence used additive integer bands. The logical-selector slice
  below replaces them with independent keys; layers and additional cascade
  levels still need complete engine support.
- Property defaults, validation, computed-value conversion and layout/paint
  consumers are distributed. Adding a grammar alone does not complete a feature.

The first implementation addresses structural parsing as a working vertical
slice. `css_rule_syntax.zig` returns borrowed rule/declaration source ranges,
retains declaration order until semantic compilation, and knows nothing about
DOM, selectors, properties or media conditions. `css_syntax.zig` supplies shared
balanced component scanning with a fixed nesting bound. Native stylesheets,
inline declaration blocks and keyframes use that structure; selectors pass
through the existing bounded selector-list entry point. The selector matcher
now depends on DOM types directly instead of the parser compatibility facade.

The slice restores final-block EOF recovery and recovery after unknown nested
at-rules. It includes an isolated `test-css-syntax` target, semantic/document
and replacement tests, the [recovery page](tests/manual/css-recovery.html),
exact pipeline captures and the [focused WPT manifest](tests/wpt/manifest-css-structure.yaml).
The same unchanged upstream cases are enabled in the default allowlist across
testharness, reftest and crashtest categories.

The focused WPT run improved from 5/8 to 7/8 passing cases. The remaining
`matching-brackets-001.xht` failure reaches CSS with its XML CDATA wrapper still
present. An isolated HTML copy with only that wrapper removed computes both
paragraphs green, so XML document loading remains a separate integration
prerequisite. Keep the upstream test and its PASS expectation unchanged.

This is a structural syntax layer, not a complete CSS tokenizer or persistent
syntax tree. Strings and escapes retain source spelling; values still need
full tokenization/normalization, including bad-token validation and EOF repair
inside values. Oversized component nesting discards the incomplete construct
and remaining input; completed earlier rules/declarations remain valid. It
neither implements CSS nesting semantics nor exposes stylesheet CSSOM objects.
Its recovery model follows [CSS Syntax](https://drafts.csswg.org/css-syntax-3/#parsing),
with the above limits made explicit rather than claiming full conformance.

## Ordered inline declarations

The second slice fixes a practical mismatch: script could read invalid values
that native styling ignored, count duplicate declarations, miss shorthand
longhands, and reorder existing properties when editing them. Inline CSSOM and
native styling now use the same Element-owned ordered block, with the existing
property grammar shared through a declaration sink. The JavaScript scanner and
hard-coded accessor list are removed; supported names come from the registry.

Following [CSSOM declaration ordering and mutation](https://drafts.csswg.org/cssom/#css-declaration-blocks),
authored duplicates keep the priority winner at its winning source position.
CSSOM setters preserve existing positions, expand shorthands, replace priority,
and ignore unsupported/invalid assignments without rewriting the attribute.
Component-aware `!important` parsing handles comments and identifier escapes,
while nested/string/URL bangs remain value data. Queries and serialization use
expanded longhands, custom-property case and pending shorthand metadata.

An inline block owns its strings independently of the attribute and is built
lazily. Raw style writes increment an attribute revision, including identical
text replacements. CSSOM edits stage a cloned block and serialized attribute
before publishing both. Native style reads the retained block, so editing one
side of `margin:var(--space)` keeps the other pending substitutions. DOM cloning
deep-copies this state: attribute text alone cannot reproduce a partially
superseded shorthand. These owners retire with the Element and retain no DOM,
layout or JavaScript pointers. The architecture documents define the contract.

`test-css-declarations` runs without native libraries. Coverage includes
priority/recovery, mutation ordering, shorthand serialization round trips and
allocation failure cleanup. Document/host tests cover atomic publication, live
attribute replacement, independent clones and computed readback. The
[interactive fixture](tests/manual/css-declarations.html) checks edits before
geometry reads. The [focused WPT manifest](tests/wpt/manifest-css-declarations.yaml)
and default allowlist enable five testharness files, one clone-isolation reftest
and one declaration-block crashtest. The pre-change baseline was 2/7 passing
files (only the reftest and crashtest passed). The implementation passes 6/7
files and 16/19 assertions, up from 6/19. The remaining file needs mutation
records and computed background-image/base-URL behavior. Its passing `all`
comparison and the limited computed-style enumeration crashtest do not prove
support for those capabilities; native/unit/page regressions provide direct
coverage. There were no WPT errors, crashes, timeouts or infrastructure failures.

Verification on 2026-09-11 used ReleaseSafe and serial build jobs. `verify`
completed all 139 steps with 832 tests passing and one skipped; all 24 pipeline
cases matched. The isolated declaration target passed 31 tests, and the new
page passed all three browser/geometry assertions and is included in `test-wpt`.
The native screenshot gate still fails on existing baselines: two SVG goldens
pass, nine other captures differ from goldens but match a cached pre-change
browser exactly below chrome, and view-source times out in both builds under
the same 30-second diagnostic limit. No golden files were changed.

That slice established the native inline declaration owner. The value-layer
work below now supplies tokenization, normalization, EOF repair and escaped
custom names. Additional property grammars, full IDL/descriptors,
MutationObserver records and stylesheet/rule identity remain separate work. Whole `Node.style` assignment
retains the existing immediate transition-start path. Shared grammar and the
owned block are now the extension point for subsequent vertical slices.

## Value tokenization and normalization

The motivating failures were equivalent CSS spellings producing different native
styles: escaped units/keywords were rejected, malformed URLs and strings could
reach permissive validators, EOF values were not repaired, and variable
substitution inserted spaces even when token identity required comment separators.

`css_tokenizer.zig` now provides the CSS Syntax lexical kinds, original source
ranges, preprocessed code points, decoded content, number type/sign, hash type,
and EOF closure state. Unicode-range tokens require an explicit descriptor
context. The structural scanner and computed-value helpers use this same lexer;
independent numeric/string/URL scanners were removed.

`css_values.zig` checks component structure and var() arguments, rejects bad
strings/URLs, repairs open strings/URLs/blocks at EOF, and normalizes supported
standard values. Numbers retain decimal precision; units/keywords decode escapes,
strings and URLs use quoted serialization, and registry metadata selects length
zero and sRGB primitive serialization after shorthand expansion. Custom data and
pending substitutions retain spelling, case and interior trivia. Escaped custom
names resolve to the same decoded identity, including dependency/cycle checks;
substitution preserves token boundaries without inventing whitespace.

Compiled declaration maps now own their normalized names/values and deep-clone
for selector lists/keyframes. Inline blocks use their existing arena. Temporary
computed substitution maps copy/intern their result before retirement. CSS URL
contents are decoded before native resource resolution, preserving resource
provenance and retirement behavior.

The implementation follows [CSS Syntax tokenization and serialization](https://drafts.csswg.org/css-syntax/),
[CSSOM values](https://drafts.csswg.org/cssom/#serializing-css-values), and
[custom-property serialization](https://drafts.csswg.org/css-variables/#serializing-custom-props).
Values are bounded to 1 MiB and 64 nested components. This completes the shared
lexical foundation, not every property's CSS grammar: advanced colors, full font
serialization, typed math simplification, all units/properties, and stylesheet
CSSOM identity still require their corresponding engine slices. Extreme numeric
spellings stay bounded and property validators decide representability.

The new `test-css-values` target runs without native libraries. Coverage includes
all lexical kinds, arbitrary-byte progress, escaped Unicode/EOF, token separation,
invalid recovery, independent cloned owners and allocation failures, CSSOM readback,
URL fetching and a [page/layout regression](tests/manual/css-values.html) included
in `test-wpt`. The focused [upstream manifest](tests/wpt/manifest-css-values.yaml)
contains five testharness cases, two escaped-value reftests and an existing
escape crashtest; the seven new cases are also enabled in the default allowlist.
The broad serialization case deliberately retains unsupported property failures.
Stylesheet-identity-dependent serialization cases were reviewed but are not newly
enabled because they exercise the older stylesheet shim rather than this owner.

The focused upstream comparison improved from 2/8 to 5/8 passing files and from
432/794 to 539/794 passing assertions, without assertion regressions, errors,
crashes, timeouts or infrastructure failures. At that checkpoint, remaining
files covered broader property/shorthand serialization, the four-argument `rgb()` alias and
`light-dark()`, and escaped selector identifiers (the companion escaped-value
case with an ordinary selector passed). The grammar slice below resolves the
alias and escaped-selector failures. Expectations remain unchanged.
The earlier declaration and structural manifests retain their prior results:
6/7 files with 16/19 assertions, and 7/8 files with 9/9 assertions, respectively.

Verification used ReleaseSafe with serial jobs. The portable `verify` aggregate
passed all 148 steps with 894 tests passing and one skipped; the unfiltered
document/render/declaration checks passed 806 tests. The pure CSS targets passed
63 tests, and all 24 pipeline cases matched. The five style golden updates were
reviewed and contain only equivalent zero-length (`0px`) and numeric color
(`rgb(...)`) serialization; layout/display-list goldens were unchanged.

The native screenshot gate passed both SVG goldens, then stopped at the existing
native-page mismatch. Its current capture matches the saved pre-change browser
exactly below chrome. No PNG goldens were changed; later screenshot cases and
interactive manual checks were not rerun for this slice.

## Property grammar and escaped selectors

This slice targets common escaped utility classes, translucent functional
colors and image positioning. The old selector scanner split escaped punctuation
and rejected escaped initial characters. RGB/HSL accepted only legacy commas;
background positioning rejected negative offsets and accepted invalid axis pairs.

Selector atoms now use the shared tokenizer/decoder for owned tag, class, ID,
attribute, pseudo and language names. Comments retain token boundaries without
becoming descendant combinators; mixed compound atoms can follow supported
pseudo-classes. Invalid identifier starts and bad strings reject the whole list.

The shared color owner validates legacy and modern absolute RGB/HSL, including
function aliases, mixed modern RGB units, slash alpha, hue units and `none`.
Specified serialization preserves alpha precision and missing HSL components;
painting uses the existing RGBA8 representation. Typed color math, relative and
wide-gamut colors, color-scheme-dependent values and color interpolation remain
separate capabilities.

`css_position.zig` owns one-to-four-value position parsing, canonical horizontal/
vertical serialization and resolution. It validates axis pairing and supports
signed offsets, edge-relative positions, existing math and font-relative units.
Painting uses actual font size, zoom and free image space, including negative
percentage bases when the image is larger than its positioning area. Layout
supplies used border widths so ordinary image positioning uses the padding box
while retaining the border-box paint clip. Background shorthand shares this
grammar, consumes size immediately after its slash and
accepts following repeat/attachment/color components. Its CSSOM serialization
round-trips through the same parser. Omitted positions reset to `0% 0%`, while
explicit unitless zero lengths serialize as `0px`. Multiple layers, origin/clip
properties, additional size units and full computed-position CSSOM serialization
remain future slices.

Coverage includes native grammar/owner tests, malformed values, allocation
failure cleanup, CSSOM substitution, selector mutations, display commands and
software pixels. The [browser regression page](tests/manual/css-grammar.html) is
part of `test-wpt`. The [focused WPT manifest](tests/wpt/manifest-css-grammar.yaml)
selects seven testharness files, six reftests and one existing escape crashtest.
Eleven cases are newly enabled in the default allowlist; DOM escapes and the
existing escaped-value reftest/crashtest were already enabled. Related background
crashtests were reviewed: their stylesheet shim, multiple layers or animation
prerequisites do not exercise this owner fully, so they were not newly enabled.

The saved-browser upstream comparison improved from 3/14 to 11/14 passing
files and from 133/292 to 228/292 passing assertions. All six reftests and the
crashtest pass, including edge offsets with borders and negative percentage
bases. There were no regressions, errors, crashes, timeouts or infrastructure
failures. The remaining 64 assertions require typed color math (62) or exact
lone-surrogate preservation in DOM attribute storage (2); CSS escapes already
decode those invalid Unicode code points to replacement characters correctly.
Upstream PASS expectations remain unchanged.

The earlier value manifest improved from 5/8 to 6/8 passing files and from
539/794 to 628/794 passing assertions, without regressions or infrastructure
failures. Its remaining failures cover broader property/shorthand serialization
and `light-dark()`.

Verification used serial ReleaseSafe builds. `verify`, `test-pipeline` and all
three pure CSS targets passed 152 build steps with 919 tests passing and one
skipped. The complete render/declaration/value run passed 599 tests, and all
24 pipeline cases matched. Five style goldens changed only the initial
`background-position: 0 0` spelling to `0% 0%`; layout and display-list goldens
were unchanged.

The native screenshot gate passed both SVG goldens, then stopped at the known
native-page mismatch (22,361 pixels against its checked-in golden). Its capture
matches the saved pre-change rendering exactly below chrome. No PNG goldens
changed. The new grammar page was captured through the native screenshot path
and shows PASS with matching bordered image panels. The nine later screenshot
cases and interactive manual checks were not rerun after the gate stopped.

The grammar follows [Selectors](https://drafts.csswg.org/selectors/#characters),
[CSS Color](https://drafts.csswg.org/css-color-4/#rgb-functions) and
[CSS Backgrounds](https://drafts.csswg.org/css-backgrounds-3/#background-position).

## Logical selector lists and explicit cascade

Component rules and low-specificity resets need `:is()` and `:where()`. The
previous matcher also accepted only a compound in `:not()` and added an extra
pseudo-class count. Numeric `100/10/1` specificity and additive origin bands
allowed sufficiently many classes or IDs to overtake stronger categories.

Logical selectors now own complex argument lists, including nested logicals,
ancestor and sibling relationships, escaped atoms and the existing supported
`:has()` subset. `:is()` and `:where()` discard invalid members; `:not()` and
ordinary selector lists reject the whole list. Empty forgiving lists match
nothing. `:is()`/`:not()` use the maximum valid argument specificity regardless
of which branch matches, while `:where()` contributes zero. Pseudo-elements
remain outside these argument lists; terminal before/after selectors match
logical conditions against their authored host and its relationships.

`css_cascade.zig` compares origin/importance, inline attachment, independent
ID/class/type counts, then source order. Counts saturate independently.
Browser and inspection rule arrays retain source order and no longer sort by
specificity. Background resource provenance uses the same winning key as its
value; computed strings retain their Element-owned lifetime after a rule
retirement. HTML hints, author declarations, inline declarations and important
UA declarations retain their separate precedence. Invalid winning variable
substitutions still compute to unset without reviving a lower declaration.

Both native DOM query paths use the same bounded selector-list entry point as
stylesheets, deduplicate matches in document order and reject invalid trailing
members. The detached-document wrapper propagates selector syntax errors.
Logical conditions carry ancestry and matching context through compounds and
`:has` caches; recursive traversal borrows stack ancestry links without adding
matching allocations. Cache pointers remain local to one DOM/rule generation.

The page-level mutation checks exposed stale style reuse after ancestor/sibling
changes. Each styled tree root now stores a scalar summary of the installed
selectors' relationships, including logical branches that currently do not
match. Mutation invalidates descendants for ancestor-sensitive rules, the
parent subtree for sibling-sensitive rules, and conservatively the full tree
when `:has()` combines with either relationship. Simple rules retain the prior
clean-subtree optimization. This is a correctness policy, not per-selector
invalidation indexing; complex relational sheets may restyle more than needed.

`css_anb.zig` validates supported nth formulas before they can contribute
specificity and matches them using widened arithmetic, preventing extreme
negative offsets from overflowing.

The selector limits remain 64 KiB of source, 256 members per list and 64 nested
blocks/functions. An+B coefficients and offsets are bounded to signed 64-bit
integers. `of <selector-list>`, namespaces, shadow/scope selectors, full relative
`:has()` grammar, pseudo-classes following generated pseudo-elements, layers
and live stylesheet-rule CSSOM are separate capabilities.

Native coverage includes forgiving recovery, specificity, generated hosts,
allocation-failure cleanup, source retirement, variable and URL winners, live
queries and mutation-driven style reads, plus layout/software pixels across
stylesheet replacement. The [logical selector page](tests/manual/css-selectors.html)
also checks immediate geometry after ancestor/sibling and inline mutations.
It is registered in `test-wpt`. The focused
[upstream selector manifest](tests/wpt/manifest-css-selectors.yaml) keeps
upstream expectations intact; WPT prerequisites and results are recorded in
[the WPT guide](tests/wpt/README.md).

The grammar and ordering follow [Selectors logical combinations and specificity](https://drafts.csswg.org/selectors/#logical-combination),
[CSS cascade ordering](https://drafts.csswg.org/css-cascade-5/#cascade-sort) and
[CSS An+B tokens](https://drafts.csswg.org/css-syntax-3/#anb-microsyntax).

Verification on 2026-09-12 used ReleaseSafe builds with `-j1` and process-group
watchdogs. `verify test-pipeline test-css-syntax test-css-declarations
test-css-values` passed 154/154 steps: 931 tests passed and one skipped. All 24
pipeline cases passed without golden changes. The complete script suite passed
241/241 on rerun; an earlier run's `replaceChildren` relocation failure did not
reproduce in isolation, the aggregate suite or the repeated full script suite.
Final documentation and formatting checks passed.

The native logical-selector screenshot shows green PASS and matching bars.
Both SVG screenshot goldens pass. The native-page golden retains its existing
22,361-pixel mismatch, with the actual page identical to the saved baseline
below the 70px chrome exclusion; the gate therefore leaves later screenshot
cases unrun. No screenshot golden was changed. Focused upstream WPT finished
at 8/17 passing files, with the remaining named-global/serialization blockers
and enabled coverage described above and in the WPT guide.

## Resolved color values and paint

The motivating failures were concrete: `getComputedStyle(...).color` exposed
`green` instead of its resolved RGB value, `color: currentcolor` failed to
inherit the foreground, and accepted `background-color: currentcolor` could
paint nothing. These affected ordinary theme/inheritance behavior as well as
the selector invalidation WPT tests.

`color.zig` now covers all 148 named sRGB colors and shares currentcolor
resolution between CSSOM and paint. The style pass resolves foreground
currentcolor through a checked parent dependency. Background/border values
keep the keyword through explicit inheritance and resolve on the receiving
element. Block, image, control and canvas backgrounds use that resolution;
transparent root colors permit body-background propagation. Canvas selection
uses alpha before paint quantization. Color-only changes retain clean geometry
and invalidate paint.

Native computed readback uses the property registry's color family to serialize
RGB/RGBA, preserving alpha precision and copying strings before returning to
Kiesel. Its live CSS/camel-case longhand accessors also come from the registry.
Inline declarations retain specified keywords; custom properties remain
case-sensitive token values. No new source, URL, thread or asynchronous owners
are introduced. Other resolved-value families, shorthand readback, pseudo-element
readback, complete CSSStyleDeclaration IDL and detached-document stylesheet
behavior remain separate work.

The [color page](tests/manual/css-colors.html), native owner/host tests and
retained-render tests cover parent mutations, inherited currentcolor, alpha,
keyword grammar, invalid substitution, copied strings and paint invalidation.
The page is part of the local WPT protocol gate. The
[focused color manifest](tests/wpt/manifest-css-colors.yaml) includes unchanged
keyword/computed tests, rendering references and malformed SVG color coverage.
Default coverage adds invalid named-color parsing, named/currentcolor rendering
and the SVG color crashtest. The existing selector invalidation case continues
to cover real computed readback.

Upstream computed-color helpers require `CSS.supports`, which is not yet
exposed. Those cases remain diagnostic in the focused manifest until native
capability queries are implemented; they were not newly enabled by default.
XHTML CDATA stylesheet loading, system/relative/wide-gamut colors, missing RGB
component preservation and typed color math remain separate limitations. Full
color/animation interpolation is also outside this slice. Missing-component
HSL resolved serialization still needs to be distinguished from specified
serialization when the computed-color helpers are unblocked.

Verification passed all 238 document, 554 render and 46 declaration tests.
The focused CSS host run passed 37/37. Final aggregate/pipeline/pure-syntax/value
verification passed 154/154 build steps and 890 tests, with one skipped. All
24 pipeline cases pass with unchanged goldens. The new local page reports 6/6
and its native capture shows green PASS with matching green bars. Render and
aggregate runs emitted GC finalization warnings but completed successfully.

The unchanged upstream selection improved from 3/16 to 5/16 passing files,
without regressions or infrastructure failures. The five computed-color files
are blocked by `CSS.supports`; two modern currentcolor references now differ
only at 231 glyph pixels by one channel level. Removing the same-color text in
a separate diagnostic makes the reference match exactly, so the remaining
pixel issue belongs to glyph compositing. The older XHTML reference failures
retain the CDATA loading limitation. All original WPT expectations are preserved.

The native screenshot gate passes both SVG cases, then stops at the existing
22361-pixel native-page golden mismatch, leaving later screenshot cases unrun.
The current native page matches this slice's saved browser exactly below the
70-pixel browser chrome. No screenshot golden was changed.

## Native feature queries

The motivating gaps were missing `CSS.supports()` during page initialization
and computed-value tests, plus ignored `@supports` blocks that left modern and
fallback styles inactive. The new [query owner](src/document/css_supports.zig)
uses the existing declaration grammar, with a strict selector capability
callback from the native parser. No external CSS dependency or second property
validator is introduced.

Implemented behavior includes both JavaScript overloads, literal CSSOM property
names, implicit parentheses for single declarations, declaration priority rules,
custom properties and pending var() values, nested `not`/`and`/`or`, future
unknown functions/enclosures, escapes, comments, EOF closure and bounded invalid
input. Selector queries accept one complex selector and reject unsupported
branches recursively, including branches that ordinary `:is()`/`:where()` parse
forgivingly. The query does not require a matching DOM element or resolved
custom-property value and never mutates or flushes style.

Feature-query review also exposed legacy validators that accepted arbitrary
non-empty values. Fifteen formatting, font, opacity, radius, object-fit and
animation grammars now reject unsupported input through the shared declaration
owner. Invalid assignments preserve earlier declarations. The animation grammar
reuses the playback parser, so unsupported fill modes are not reported as
implemented. Other legacy SVG/paint grammars remain permissive and need their
own grammar/used-value slices; feature-query coverage does not establish full
property conformance.

Native `@supports` activates rules and keyframes in authored order through nested
media/supports groups. Allocation failure releases query and nested generation
owners; inspection publication tests preserve old source, rules, keyframes,
computed values and subscriptions at every allocation failure. JavaScript tests
cover namespace shape, overload conversion, exceptions and unchanged inline
storage. Native rendering tests exercise actual geometry/software pixels across
media reselection and source replacement. The
[feature-query page](tests/manual/css-supports.html) checks API/rule agreement and
responsive bars and is part of the local WPT gate. `test-css-supports` provides a
pure query-grammar/cleanup target.

The [focused supports manifest](tests/wpt/manifest-css-supports.yaml) reviews
Conditional Rules Levels [3](https://drafts.csswg.org/css-conditional-3/) and
[4](https://drafts.csswg.org/css-conditional-4/) through unchanged API,
CSSStyleDeclaration consistency, conditional rendering, invalid nested rules,
keyframes, custom-variable and crash cases, plus newly reachable computed-color
helpers. The default allowlist enables 48 of the 50 cases, including unresolved
RGB/HSL serialization/color-arithmetic and sticky-position assertions. CSS
nesting and the keyframe reference requiring animation fill modes stay diagnostic.
Live CSSStyleSheet/CSSSupportsRule identity, namespace maps, CSS nesting inside
style rules, quirks-mode declaration parsing,
font-format/font-tech queries and unsupported property/selector families remain
separate capabilities. Unknown query functions evaluate false.

The unchanged 50-case upstream comparison improved from 3 to 45 passing files
and from 133 to 5858 passing assertions out of 5933. All four conditional API
files pass. The five remaining file failures are RGB/HSL serialization and color
arithmetic, CSS nesting, animation fill modes and positive position parsing.
At that stage the position case rejected `sticky`, which the old permissive parser accepted
without implementing its layout behavior. This is an intentional admission
correction; the subsequent implementation is described below. That run completed without
timeouts, crashes or infrastructure failures.

Verification after the shared grammar corrections passed all 161 build steps:
1006 tests passed and one skipped across the aggregate and pure CSS targets,
including 881 passing unified tests. All 24 pipeline goldens remain unchanged.
The complete pure CSS/document iteration passed 352 tests, and the focused
query/host/publication checks passed before the aggregate. The five-check local
feature-query page is part of the aggregate gate. Native jobs run serially with
process-group watchdogs; GC finalization warnings remain separate from results.

Native captures of the new page at 800px and 400px show green PASS and three
matching bars that change width with the media condition. Both SVG screenshot
goldens pass. The native-page golden still differs by 22361 pixels, while the
new capture matches the saved pre-change browser exactly below the 70px chrome
exclusion. No PNG goldens changed; the nine subsequent screenshot cases and
interactive window-resize checks remain unrun.

## Color calculations, nesting, animation phases and sticky positioning

The feature-query tests exposed four concrete engine gaps: RGB/HSL calculation
and missing-component serialization, nested style rules inside conditional
groups, keyframes whose fill mode was rejected, and `position: sticky` without
working layout. These now have native implementations across parsing, style,
paint and script readback.

- `css_math.zig` shares bounded typed arithmetic across lengths, colors and
  animation times. It handles nested `calc`/`min`/`max`/`clamp`/`abs`/`sign`,
  angle conversion, explicit percentage hints and non-finite channel results.
  Style resolves font-dependent color/time calculations and registers their
  dependencies. Missing RGB components serialize via `color(srgb ...)`; HSL
  preserves `none` and percentage units. Native color interpolation now uses
  premultiplied alpha, avoiding a transparent endpoint's RGB tint.
- `css_nesting.zig` lowers explicit `&`, implicit descendants and relative
  selectors through the existing selector compiler. Parent-list specificity,
  declarations after nested rules, nested media/supports and source replacement
  retain normal cascade semantics. Lowered source and recursive depth are
  bounded; compiled rule owners retain no temporary selector strings.
- Animation shorthand expands into eight longhands. Playback samples active,
  delay and completed phases for every fill mode, negative delays, fractional
  iterations, reverse/alternate directions and paused state. Missing endpoints
  use underlying values; important declarations override effects. Completed
  fills remain visible without keeping the frame scheduler busy. Same-name
  longhand edits preserve elapsed time. Specified time units and computed seconds
  have separate serialization, and computed shorthands share the declaration
  serializer instead of retaining a competing animation string.
- Sticky retained blocks stay in normal flow and use independent visual
  offsets. Pure axis constraints account for the nearest scrollport, containing
  edges, margins, negative/percentage insets, oversized boxes and nested sticky
  ancestors. Scroll updates refresh paint, painted hits and CSSOM geometry
  together without relayout. Element horizontal/vertical offsets, overflow
  dimensions and immediate scroll methods now reach actual native scroll state;
  hidden overflow is programmatically scrollable but excludes native scroll input.

The [page regression](tests/manual/css-completion.html) runs in the local WPT
gate and checks font changes, nested-selector invalidation, paused fill-mode
edits, scroll clamping and sticky rectangles. Native tests cover constraint
limits, zoom, paint provenance, phase transitions, shorthand precedence and
allocation cleanup. The [focused upstream selection](tests/wpt/manifest-css-completion.yaml)
reviews testharness, reftest and crashtest cases; meaningful additions are also
enabled in the [default allowlist](tests/wpt/manifest.yaml): 45 additional cases.
CSSOM selectorText invalidation, named-window-global dependencies, the
scroll-timeline/automatic-duration file and a CDATA-bearing XHTML reference
remain diagnostic because those prerequisites are separate features.

Verification: `zig build verify -Doptimize=ReleaseSafe -j1` passes all 155
steps, with 899 tests passing and one skipped, including all 24 pipeline cases
and the four page assertions. The four isolated CSS roots pass 135/135 tests.
The upstream comparison improves from 14/57 to 41/57 passing files and from
3938/4154 to 4063/4154 passing assertions, with no previously passing file
regressing. A 60-second per-case deadline lets the large computed-HSL matrix
finish; the final run has no crashes, timeouts or infrastructure failures.
The [WPT report notes](tests/wpt/README.md#color-calculations-nesting-animation-and-sticky)
distinguish semantic gaps, prerequisite failures and 25 specified-color
assertions whose older missing-component expectations disagree with the draft.
The earlier feature-query selection now passes 48/50 files and 5929/5933
assertions; only four container-unit color calculations still fail.

Wide (1280×800) and narrow (500×800) native captures of the page fixture both
show PASS and the correct media-dependent widths. The SVG-inline and SVG-image
screenshot goldens pass. The screenshot gate still stops at the pre-existing
native fixture mismatch of 22,361 pixels; its final capture is pixel-identical
to the saved browser across the entire frame. PNG goldens are unchanged.
The remaining screenshot cases after that failed dependency and human wheel/
Reset-button interaction checks have not been completed in this pass.

Remaining boundaries are explicit:

- Size-container units (`cqw` and related units) require an actual containment
  and layout dependency contract. They remain unsupported in color/time math.
  Relative calculation strings preserve their semantics, but full canonical
  algebraic serialization and additional color spaces/functions remain work.
  Some checked-in specified-color WPT expectations discard `none` or omit HSL
  percentage units; the implementation follows the current
  [CSS Color serialization rules](https://drafts.csswg.org/css-color-4/#serializing-sRGB-values),
  which preserve them. Expectations are not rewritten to conceal that difference.
- Animation playback remains one frame-driven name with endpoint interpolation
  for opacity, background-color, translation, width and height. Multiple effects,
  intermediate keyframe segments, wall-clock sampling, animation events, WAAPI
  and scroll-linked timelines need separate vertical slices.
- Sticky supports retained block boxes in horizontal LTR layout. Fragmented and
  temporary atomic-inline boxes need retained constraints that survive snapshot
  retirement. Horizontal root scrolling, reversed/RTL ranges, overflow-axis
  longhands, scroll events and smooth scroll APIs remain separate capabilities.

## Development direction

Choose complete capabilities from representative-page failures and shared engine
dependencies.

Native `CSS.supports` and `@supports` now share declaration and selector grammar
and unblock the upstream computed-value helpers. Use those newly reachable
failures to choose the next complete property/computed-value slices.

Continue the other foundation slices:

1. **Property grammar slices:** build on the shared lexer, normalization and
   ordered declaration owner. Add each family through CSSOM, specified/computed
   values and layout/paint, with malformed values and custom substitution
   included. Keep primitive serialization policy in the property registry.
2. **Shared stylesheet generations:** integrate retained sheets into Frame
   loading/replacement and media selection without changing source retirement,
   URL provenance, navigation or synchronous geometry-read contracts. Preserve
   conditional rules independently of the current viewport and avoid reparsing
   unchanged syntax. Add stable identities before exposing live rule handles.
3. **Cascade extensions:** build layers and further cascade levels on the
   explicit origin/importance, inline attachment, specificity and source-order
   keys. Implement each with parsing, matching, precedence and invalidation
   coverage; do not restore additive numeric bands.
4. **Property families:** extend specified/computed/used values together with
   their layout and paint consumers. Prefer a coherent capability that fixes
   representative pages to isolated recognition of many unsupported names.

### Syntax and recovery

Use the shared bounded tokenizer for new value and CSSOM capabilities. Do not
add a second parser backend. Preserve
source ranges, token boundaries and diagnostics independently of property
validation, and define progress/cleanup for malformed input and allocation
failure. Keep the existing URL, string, escape and nested-block regressions.

### Stylesheet ownership and JavaScript APIs

Keep source/provenance ownership explicit, with rules retired before the source
strings they borrow. Inspection already stages replacement rules before
publication and separates publication from fallible restyling. It reparses
retained sources when media changes. Future retained syntax must preserve these
contracts while avoiding unnecessary reparsing.

Introduce stable stylesheet/rule identity before exposing `styleSheets`,
`cssRules`, rule insertion/deletion or rule-style mutation. JavaScript must
operate on the model used for styling, with defined behavior after removal,
replacement and navigation. Keep inline CSSOM on its native declaration owner
and define stylesheet serialization against the retained rule model. Source
spelling is not automatically CSSOM serialization.

### Selectors and cascade

Retain the shared selector admission checks, forgiving logical-list behavior
and unforgiving ordinary/negation lists. `:is()`, `:where()` and complex-list
`:not()` now share matching and independent specificity counts. Extend the
explicit cascade key for further origins, layers and animation/transition
precedence. Treat `@supports`, layers,
nesting and other rule semantics as separate capabilities with focused tests.

### Values and rendering

Keep property validation and shorthand expansion shared between stylesheets and
inline styles. Extend typed values by property family while preserving
specified/computed/used-value distinctions and symbolic units until their basis
exists. Preserve variable cycles/fallbacks, invalid-at-computed-value behavior,
root-relative dependencies, and generated-box invalidation across failed passes.

Prioritize sizing, fonts, colors and layout algorithms from concrete page
failures. CSS syntax work is not a prerequisite for independent rendering fixes.

## Verification

Follow the [testing guide](docs/testing.md). Each chunk should record its
motivating failure, owner, focused tests, applicable unchanged WPT cases and
remaining limitations. Preserve reclaiming-allocator tests for replacement,
failed restyle, inherited dependencies, and source retirement.

The [pipeline manifest](tests/pipeline/manifest.zig) includes exact narrow/wide
cascade, shorthand, variable and inline-style coverage. Native inspection
render tests exercise geometry, paint and software pixels after media and
stylesheet changes. Keep these checks when evolving the parser.

The [CSS syntax](tests/wpt/manifest-css-frontend.yaml) and
[CSS interop](tests/wpt/manifest-css-interop.yaml) manifests remain native-browser
baselines. Missing stylesheet APIs are distinct from parser failures. Review
the [default WPT allowlist](tests/wpt/manifest.yaml) for each expanded capability,
including testharness, reftest and crashtest coverage; do not change upstream
expectations to hide failures. Broad sweeps are periodic health checks.

For every added CSS capability, cover all applicable stages: property/at-rule
metadata, syntax, specified values and shorthands, cascade/computation,
inheritance and invalidation, layout/paint, JavaScript readback/mutation, resource
provenance/lifetime, and unit/page/WPT verification. Explicitly state when a
stage does not apply; a parsed declaration alone is not feature completion.

Run `test-css-syntax` for structural parsing and `test-document` for semantics
and ownership while iterating, then relevant pipeline, aggregate
and native checks. Use serial native jobs with process-group watchdogs and
cleanup. Report timeouts, known baseline mismatches and unrun platform/manual
checks separately from successful verification.

### First slice verification

The final focused run passed all 9 structural syntax tests, 206 document tests,
24 pipeline goldens, formatting and documentation checks. The final installed
browser retained the 7/8 focused WPT result described above.

An initial aggregate completed with 823 tests passing and one skipped. After
the final malformed-input recovery guard, two aggregate attempts reached the
900-second watchdog. The repeat also reported a failure in
`verified insertBefore mutation retains document and matched block layouts`;
that test passed when run alone through `test-render` (1/1). The aggregate is
therefore not consistently green, and that integration failure remains open.
The full native screenshot suite and manual interaction checks were not rerun.
