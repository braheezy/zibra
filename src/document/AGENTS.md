# Document subsystem guide

This directory owns HTML parsing, DOM representation, CSS parsing, selectors,
computed style, and pure helpers for document-backed rendering features.

Read [document and rendering contracts](../../docs/architecture/document-and-rendering.md)
before changing DOM storage, source buffers, mutation, style invalidation, or
layout callbacks. Read
[JavaScript and accessibility contracts](../../docs/architecture/javascript-and-accessibility.md)
for exported Node handles, focusability, canvas wrappers, or script-visible
behavior. Navigation-owned stylesheet/resource generations are documented in
[navigation and network](../../docs/architecture/navigation-and-network.md).

## Ownership rules

- Parser-created text, lowercase HTML names and undecoded attributes generally
  borrow document buffers. Compiled CSS declarations own their names and values.
  A Frame's
  `html_source.Store` owns initial and parser-inserted HTML chunks through DOM
  retirement; never resize a chunk once a Node borrows it. Element
  decoded strings, images, canvas pointers, animations, and detached subtree
  resources are explicit owners. Do not retire backing text first.
- Script-created text nodes duplicate their payload and mark it as owned so
  detached-node teardown can release it without confusing parser-borrowed
  source slices for allocations. Non-ASCII script text additionally owns exact
  UTF-16 units; its UTF-8 bytes are a scalar projection, not the authoritative
  DOMString. Move both owners together and retire layout before replacing them.
- `attributes.zig` owns an ordered attribute map whose strings borrow source
  or `Element.owned_strings`. Updating a name keeps its slot; deleting uses
  `orderedRemove`, and reinserting appends. Do not cache entry pointers across
  mutation or reintroduce hash iteration order in JavaScript views.
- Children are Node values in resizable arrays. Never retain a child `*Node`
  across structural mutation unless the synchronous mutation transaction
  invalidates or rebinds every consumer before control escapes.
- `fixParentPointers` must also rebind computed-style field owners because
  inherited invalidation callbacks retain those owner pointers.
- Custom-property environments own their computed strings. Their protected
  version publisher is separately heap-stable because registered fields cannot
  move with Node values. Clear dependencies at the structural mutation boundary.
- `HTMLParser.parse` returns its root by value. Store it in its final owner,
  then call `fixParentPointers(&root, null)` before style, layout, DOM
  ancestry, or JavaScript uses it; the parser cannot repair pointers after
  that return-value move.
- `html_fragment.zig` stages an inert fragment with the same parser. Transfer
  its source to the Realm before publishing or moving its children; a temporary
  parsing container must not own the only copy of their source. Text allocation
  ownership and character-reference encoding are independent flags.
- `xml_parser.zig` builds detached DOMParser and temporary SVG image trees. Its successful tree
  borrows the caller-owned source buffer, preserves XML name case, and must be
  retired before that source buffer is released. Image callers set explicit
  depth/element limits before parsing to bound allocation and recursive teardown.
- Rules, named keyframes, and the source text they borrow move and retire as
  one generation. Stage a complete replacement before dropping the prior one.
- Live HTML serialization reads current attributes/tree, sorts attribute names,
  quotes/escapes values, preserves source-backed text without double escaping,
  and omits children/closing tags for void elements.
- Generated `:before`/`:after` boxes are private heap-stable Nodes owned by
  their host Element. They are not child-array entries or script-visible DOM
  nodes; layout injects active boxes in before/authored/after order.

## Mutation and invalidation

- Structural mutation enters the dedicated host boundary after staging
  fallible owners and before child storage moves. Ordinary render callbacks are
  separate and must not discard interaction state for a style-only change.
- General mutation clears current style subscriber maps while endpoints are
  alive, dirties the installed style tree, and rebuilds layout. The verified
  insertion-only exception preserves endpoints and immediately rebinds matched
  layout pointers.
- Elements install separate synchronous layout and paint callbacks on the
  nearest persistent layout owner. Clear both when that owner retires.
- Each Element's `has_dirty_style_descendants` permits clean subtree skipping.
  Raise it for selector changes and inherited notifications; clear only after
  requested descendants finish successfully.
- Detached retained subtrees keep style maps but dirty every field and clear
  layout back-pointers. Reattachment registers inherited dependencies against
  the new parent.
- Attribute/inline-style and dynamic-state changes use the styled tree root
  relationship summary to invalidate affected selector dependents. Preserve
  this scalar policy across a style pass; see the architecture contract.

## CSS rules

- `css_display.zig` shares the supported display vocabulary and distinguishes
  inner flex/grid formatting from outer atomic-inline participation. Keep
  admission, intrinsic measurement and final layout dispatch consistent.
- `css_overflow.zig` owns physical overflow grammar, simultaneous computed-pair
  coercion and pointer-free axis predicates. `overflow` is a shorthand; computed
  fields are `overflow-x`/`overflow-y`. Layout publishes Element's separate used
  policy and geometry; paint must not repeat root/body viewport selection.
  Programmatic permission, user permission and reported overflow dimensions
  remain independent; see the overflow contract in document and rendering.
- `css_aspect_ratio.zig` owns ratio admission and serialization for both ordinary
  and replaced boxes. Degenerate ratios are valid syntax with no used ratio.
- `css_sizing.zig` owns preferred/minimum/maximum sizing value admission;
  intrinsic width keywords retain their identity through used layout.
  `css_alignment.zig` owns property-specific box-alignment grammar and the
  multi-token `place-items`/`place-content` split. These helpers retain no DOM
  data; intrinsic block-axis sizing and fit-content functions remain deferred.
- `css_grid_placement.zig` owns numeric grid lines/spans and row/column flow
  grammar. Placement shorthands expand through the common declaration sink;
  integer token validation precedes number normalization. Large authored
  integers keep their CSSOM spelling independently of bounded used placement.
  Named lines/areas and calculated line numbers remain outside this grammar.
- `css_math.zig` evaluates bounded typed calculations with explicit unit and
  percentage contexts. Lengths and colors share it; layout-dependent units
  must not be guessed during declaration admission. Its optional transient
  `css_math_tree.zig` output simplifies specified calculations without resolving
  relative units; do not add a second expression parser for serialization.
- `css_nesting.zig` lowers nested selectors into bounded owned temporary
  source. The shared selector compiler owns the resulting AST. Preserve parent
  list specificity and declaration/rule source order during lowering.
- `css_animation.zig` owns animation grammar and pure timeline phases;
  `animation.zig` stores scalar templates and samples. Inactive delays and
  completed fills must not overwrite the underlying computed style.
- `css_supports.zig` shares declaration grammar with CSSOM and stylesheets.
  Keep `CSS.supports` and `@supports` on that evaluator; selector queries use
  strict recursive admission even where ordinary logical lists are forgiving.
  Queries retain no source or DOM state. Allocation failure must abort staged
  stylesheet publication, not become an unsupported feature under `not`.
- Stylesheet selector lists are unforgiving and expand into independent rule
  owners. Keep rules in source order; `css_cascade.zig` compares independent
  precedence keys during styling. Do not sort by specificity or shallow-copy
  owning declaration maps. Logical-list and matching contracts live in the
  [document architecture](../../docs/architecture/document-and-rendering.md).
- Compiled declaration maps own normalized names/values and must be deep-cloned.
  Structural ranges and keyframe names still borrow source. Preserve quotes, escapes,
  comments, and typed block/function depth while scanning; stop only at top-level
  separators.
- Shorthand expansion happens in source order and preserves declaration-local
  `!important`. Add precedence tests in both shorthand/longhand directions.
- Keep computed-property defaults and inheritance policy synchronized with
  parser support. Element computed values are static defaults or interned in
  the Element's string owner, never borrowed from replaceable rule/attribute
  text. Inherited Text values borrow stable ancestor computed storage;
  used-value validation belongs in the focused helper/layout owner.
- Root, iframe and inspection callers select retained rule/keyframe programs
  when width, height, zoom, or preferences change. Keep sheet media and nested
  conditions composed; see the
  [retained stylesheet contract](../../docs/architecture/document-and-rendering.md#retained-stylesheet-ownership)
  before changing source retirement or separate publication/restyle phases.
- Descendant selectors receive ancestors in document-root-to-parent order.
  `:has` caches are ephemeral synchronous borrows and selector-relevant
  changes invalidate ancestor matches.
- Dynamic `:hover` and `:focus-visible` state is installed by the serialized
  Tab worker and must dirty style before matching.
- The current bounded generated-content implementation renders only
  `content: ''` and `content: ""` boxes. Do not expose text-bearing generated
  content until it has an owned text-node lifetime and DOM-boundary design.

## Focus, controls, canvas, and images

- `focus.zig` is the canonical intrinsic programmatic/sequential focusability
  policy. Layout visibility is a separate current-generation check.
- Checkbox state is only the presence of `checked`; hidden/password inputs keep
  one real DOM value. Never introduce parallel widget submission state.
- Canvas backing is lazily heap-stable because z2d Context points into it.
  Dimension assignment resets pixels and drawing state even when unchanged.
- HTML image null data means nonterminal load state; success and broken fallback
  install owned terminal ImageData. Background resource identity is selected
  only after cascade and owned by the Element.
- `background_image.zig`, `object_fit.zig`, `length.zig`, `easing.zig`, and
  related helpers stay pure of Browser/network/native state.
- `css_gradient.zig` borrows linear-gradient syntax and serializes values;
  `gradient_line.zig` owns copied used stops. Compute font units before
  inheritance, retain currentcolor until the receiving element, and resolve
  percentage stops against the gradient line only when its box exists.
- `css_position.zig` shares single-layer axis grammar and serialization with
  background paint. Resolve using the caller's font, zoom and actual image
  dimensions; image position percentages may have a negative basis.
- `color.zig` shares absolute color grammar, original-space serialization and
  currentcolor resolution between native paint and CSSOM. `color_space.zig` owns
  pure conversion and bounded sRGB gamut mapping. `color_mix.zig` owns borrowed
  mix syntax and weights; `color_interpolation.zig` owns scalar conversion,
  missing-component handling and interpolation shared with animations. Preserve modern coordinates
  and missing components independently of the RGBA8 paint projection. Keep
  nested background/border currentcolor symbolic through inheritance; color depends
  on its parent.

## Parser structure

Explicit `html`, `head`, and `body` starts create nodes that implicit-tag logic
would otherwise create; do not process the same token through both paths.
Nested button starts implicitly close the active button, while other
descendants remain within the current button for layout and activation.

The document pipeline is split by ownership and algorithm boundaries:

- `dom.zig` owns `Node`, `Element`, and `Text` representation, Element-backed
  resources, parent/style-owner rebinding, and DOM invalidation callbacks.
- `html_source.zig` owns stable HTML source chunks for a navigated document;
  `html_tokenizer.zig` borrows append-only chunks and emits owned lexical
  tokens across chunk boundaries. `html_parser_session.zig` remains a one-shot
  inspection/compatibility caller, while initial Browser navigation uses the
  resumable live parser directly.
- `node_pins.zig` owns parser-local opaque identities for relocation-prone
  Nodes. Pins are non-owning and only cross one synchronous storage move as
  scalars: unpublish before the move, rebind or retire before a callback, and
  retire all pins before the DOM/source generation ends. Its generic
  relocation-observer adapter is installed by the caller only around direct
  parser-script evaluation; it never makes the parser import the script host.
- `html_live_parser.zig` owns the resumable token-to-DOM path for
  parser-blocking classic scripts. It installs a final-address root before
  parsing and carries only parser-local node pins across its pause boundary;
  its caller owns direct script evaluation and the temporary document.write
  sink.
- `referrer.zig` applies HTML meta/element policy rules over synchronous DOM
  borrows. Call insertion hooks only for the inserted subtree, never rescan
  the document on removal: policy follows mutation order, not tree order.
- `html_parser.zig` is the stateful tokenizer/tree builder. It borrows one
  stable decoded HTML chunk and receives DOM types plus final parent-pointer
  repair through a comptime boundary, so it does not import the compatibility
  facade.
- `html_serialization.zig` is a generic leaf that traverses the live DOM,
  escapes attributes, and applies void-element rules without owning nodes or
  source buffers.
- `css_syntax.zig` is a pure bounded scanner for CSS comments, escapes,
  strings, URLs and balanced component delimiters. `css_rule_syntax.zig` owns
  borrowed rule/declaration ranges and recovery; it has no DOM/property/media
  dependencies. Keep unknown at-rule and EOF handling here, not in new semantic
  handlers. `css_properties.zig` is the static computed-longhand registry.
- `css_declarations.zig` owns property validation, shorthand expansion and
  declaration precedence. Its sink interface serves both stylesheet maps and
  `css_declaration_block.zig`, the independently owned ordered inline block.
  Stage CSSOM edits before Element publication; preserve pending substitutions
  and nested color precision through cloning instead of reparsing serialized text. Raw style writes must
  use attribute map mutation APIs so their revision invalidates the block.
- `css_stylesheet.zig` owns source, provenance and compiled conditional programs
  shared by Frame and inspection. Its selection builder registers all active
  sheets before resolving layer order; do not append independently ranked
  single-sheet selections into a document. Selections clone executable data into
  their destination allocator. Retire selections before the source that their
  keyframe names borrow; this is not live CSSOM identity.
- `css_layers.zig` owns decoded layer declarations and temporary per-origin
  trees. Published rules retain scalar ranks only; see the
  [retained stylesheet contract](../../docs/architecture/document-and-rendering.md#retained-stylesheet-ownership).
- `media_query.zig` owns allocation-free media condition/range evaluation over
  borrowed preludes and an explicit environment. Keep it independent of DOM,
  native windows, and stylesheet storage; callers own environment invalidation.
- `presentational_hints.zig` translates supported HTML presentation attributes
  into temporary low-priority author declarations. Intern winners before its
  arena ends; keep stylesheet cascade origin separate from source ownership.
- `css_tokenizer.zig` owns allocation-free CSS tokenization and source decoding.
  `css_values.zig` validates/normalizes component values into caller storage;
  `css_value_tokens.zig` rewrites rem dimensions without touching strings/URLs. `custom_properties.zig` owns
  immutable computed variable environments and bounded substitution/cycle
  resolution. `css_flex.zig` and `grid_tracks.zig` own the supported sizing
  grammar; they do not traverse DOM or register dependencies.
- `css_cascade.zig` owns scalar precedence keys; `css_anb.zig` owns shared
  token-based nth-formula admission and matching. Neither owns DOM data.
- `pseudo.zig` owns the shared before/after identity used by DOM storage,
  selector matching, and style application; it owns neither Nodes nor styles.
- `animation.zig` owns pure CSS transition/keyframe value objects stored by
  Elements. It does not decide whether an animation dirties compositor,
  paint, or layout; the Tab driver owns that phase decision.
- `svg.zig` supplies synchronous SVG membership and presentation hints;
  `svg_animation.zig` samples bounded declarative animation into Element-owned
  strings without changing authored attributes. Neither schedules work nor
  keeps node pointers across a callback.
- `style_application.zig` owns computed-property defaults, cascade,
  inheritance, animation-track updates, and the style-pass algorithm behind a
  narrow comptime DOM/callback interface. It never owns a Node or layout
  object.
- `style.zig` binds that generic style application to `dom.zig` and exports
  Zibra's concrete style-pass API.
- `parser.zig` is the stable compatibility entry point. It re-exports the DOM,
  HTML parser, serialization, animation, and style APIs for existing callers;
  it is not an additional owner and must stay an acyclic, logic-free facade.

`inspection.Page.load` returns the root by value. Repair parent pointers after
the returned page reaches its final address before any ancestry-dependent
style/layout/paint operation.
`loadWithMedia` takes an explicit viewport environment for inspection; its
conditional rules and the caller's layout dimensions must describe the same
viewport. Every inspection entry point uses the same native CSS parser.
Inspection entry points construct neither Browser nor native state. Retire
layout/display consumers before `reselectMedia` or `replaceStylesheet`; after
successful publication, finish the separate `restyle` before rebuilding them.

Add new grammar/data owners in focused modules rather than putting logic in
the compatibility entry point. Avoid facade cycles or splitting methods away
from the DOM/style invariants they maintain.

## Verification

Run `zig build test-css-values` for isolated tokenization/normalization,
`zig build test-css-syntax` for isolated structural parsing and
`zig build test-css-declarations` for ordered blocks/property grammar, then
`zig build test-document` for semantic and ownership changes. Run `zig build test-pipeline`
for exact style/layout/display output and `zig build test-dump-dom` for parser
serialization. Before handoff run `zig build verify`; use native macOS
screenshots only for final pixel behavior. Add/update a primary fixture in the
[manual catalog](../../tests/manual/README.md) for visible interaction.
