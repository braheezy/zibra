# CSS frontend retirement record

Decision: remove the experimental Terence integration and continue with
Zibra-owned CSS syntax. The [CSS plan](../CSS_PLAN.md) supersedes the earlier
library-adoption phases. Terence is no longer a build dependency, there is no
alternate parser selection flag, and all browser/inspection entry points use
the native parser.

## Preserved work

- Shared property validation, shorthand expansion and declaration precedence
  in [css_declarations.zig](../src/document/css_declarations.zig).
- Native selector parsing/admission checks and source provenance handling.
- Style dependency and allocation-failure fixes, including inherited values,
  root-relative dependencies and generated boxes.
- Inspection-owned stylesheet source/provenance, staged publication, and
  retryable restyling. Selections now use the native parser and reparse retained
  source for media changes; no Terence AST or normalization storage remains.
- Native document/render regression coverage for source retirement, replacement,
  media changes, failed allocations, layout geometry, paint and software pixels.
- The [cascade pipeline fixture](../tests/pipeline/css-cascade.html), with its
  original narrow/wide expectations and only the renamed link reflected in the
  style dumps.
- The unchanged upstream cases in the [syntax](../tests/wpt/manifest-css-frontend.yaml)
  and [interop](../tests/wpt/manifest-css-interop.yaml) manifests. These always
  exercised the native browser, so removing the inspection experiment does not
  change their engine coverage. The default allowlist is unchanged: this
  retirement adds no new web-exposed capability.

## Removed experiment and known gaps

The dependency, generated import bridge, syntax adapter, admission wrapper,
normalization layer and inspection inline-declaration cache were removed.
AST-specific tests and duplicate backend pipeline runs no longer apply.

The [manual recovery fixture](../tests/manual/css-recovery.html) retains the
known native gaps for declarations after unknown nested at-rules and a final
rule closed by EOF. The old experimental path produced two 120px green bars;
the native parser currently produces two 24px bars, with the second red. Those
experimental recovery goldens are not relabeled as passing native behavior.
Escaped color-value normalization and comment-separated importance likewise
remain native-parser work; retaining syntax is not equivalent to CSSOM support.

## Removal verification

The complete native document suite, including provenance ownership and
allocation-failure coverage, passes. Documentation links and formatting pass.
The six retained cascade goldens differ only in their stylesheet filename.

Render and pipeline checks were attempted in Debug and ReleaseSafe, and the
portable `verify` aggregate was attempted in Debug. Native compilation is
blocked by the installed Zig/macOS C++ toolchain: libc++ reports an undeclared
`INFINITY` in `__random/clamp_to_integral.h`. These are not passing rendering or
CLI checks. Screenshots and interactive checks were not rerun after removal.
No new WPT subsets were enabled because this removes an inspection-only backend;
the existing native-browser manifests and their expectations are preserved.

## Historical verification baseline

These observations predate removal and are retained to avoid treating known
failures as new regressions. They are not verification of the removal itself.

The 2026-09-08 CSS acceptance work reported 218 passing document tests and 45
pipeline captures across both parsers. Its unified suite had an intermittent
`removeChild` detach/reattach failure; a direct rerun passed 808/808. The source
of that intermittent failure was unresolved.

The native screenshot suite passed the SVG inline and image goldens, then
failed `native-screenshot` with 22,361 differing page pixels, maximum channel
delta 255, first difference at (30, 85). This exact mismatch also reproduced
after the audio merge. The previous CSS review independently checked the
remaining serial fixtures: view-source timed out, and eight others differed
from stored goldens. No PNG goldens were changed.

The audio-merge verification passed network, focused audio, pipeline, local WPT,
CSP, referrer, server, formatting and documentation checks. Its full ReleaseSafe
aggregate timed out during compilation. Real-device audio remained opt-in and
was skipped. Current checks and any remaining limits must be reported separately
when handing off subsequent changes.
