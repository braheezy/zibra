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
| [css_parser.zig](src/document/css_parser.zig) | Stylesheet/declaration syntax, selector parsing, media/keyframe parsing and executable rule types |
| [css_syntax.zig](src/document/css_syntax.zig) | Comments, escapes, strings and structural delimiters |
| [css_declarations.zig](src/document/css_declarations.zig) | Shared property validation, shorthand expansion and declaration precedence |
| [css_stylesheet.zig](src/document/css_stylesheet.zig) | Inspection-owned source and provenance; native parsing into borrowing selections |
| [selector.zig](src/document/selector.zig) | Selector ownership, matching and specificity |
| [style_application.zig](src/document/style_application.zig) | Cascade, inheritance, computed values, animation updates and invalidation |
| [css_properties.zig](src/document/css_properties.zig) | Computed longhand registry and defaults |
| [custom_properties.zig](src/document/custom_properties.zig) | Variable environments, substitution, cycles and expansion limits |
| [length.zig](src/document/length.zig), [color.zig](src/document/color.zig) | Supported value grammars and conversions |
| [CSS style runtime](src/script/runtime/css_style.js) | Current JavaScript inline-style interface |

The [document and rendering contract](docs/architecture/document-and-rendering.md)
is authoritative for ownership and invalidation. This plan describes future
work rather than defining a second lifetime contract.

## Development direction

Choose bounded capabilities from failures on representative pages. Diagnose
syntax, property validity, cascade, computed values and layout separately.
Improving parsing alone does not implement modern at-rules or layout algorithms.
Preserve existing supported behavior while changing one boundary at a time.

### Syntax and recovery

Fix native CSS error recovery against the CSS Syntax specification. The
[manual recovery fixture](tests/manual/css-recovery.html) preserves two known
gaps from the earlier experiment: declarations following an unknown nested
at-rule, and the final qualified rule when its closing brace is missing at EOF.
Correct behavior produces two 120px green bars; current native behavior does
not. Keep these failures visible until fixed with automated coverage.

As grammar requires it, consolidate scanning into a Zibra-owned tokenizer and
structured syntax representation. Preserve declaration order, duplicates,
source ranges and token boundaries before semantic validation. Design shared
entry points for stylesheets, declaration lists and component values. Bound
source size, token/node construction, nesting, allocation and recovery work;
parser correctness includes progress and cleanup on malformed input and OOM.

### Stylesheet ownership and JavaScript APIs

Keep source/provenance ownership explicit, with rules retired before the source
strings they borrow. Inspection already stages replacement rules before
publication and separates publication from fallible restyling. It reparses
retained sources when media changes. Future retained syntax must preserve these
contracts while avoiding unnecessary reparsing.

Introduce stable stylesheet/rule identity before exposing `styleSheets`,
`cssRules`, rule insertion/deletion or rule-style mutation. JavaScript must
operate on the model used for styling, with defined behavior after removal,
replacement and navigation. Consolidate the current JavaScript declaration
scanner with native parsing when the required readback/serialization boundary
exists. Source spelling is not automatically CSSOM serialization.

### Selectors and cascade

Retain the native selector admission checks and invalid-list behavior. Add
modern selectors such as `:is()` and `:where()` with their specified list and
specificity rules. Introduce explicit cascade precedence as needed for origins,
importance, layers, inline styles and source order. Treat `@supports`, layers,
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

Run focused subsystem tests while iterating, then relevant pipeline, aggregate
and native checks. Use serial native jobs with process-group watchdogs and
cleanup. Report timeouts, known baseline mismatches and unrun platform/manual
checks separately from successful verification.
