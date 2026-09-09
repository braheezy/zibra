# Document, invalidation, layout, and rendering contracts

This document is authoritative for source-buffer lifetimes, structural DOM
mutation, style/layout invalidation, retained paint, command snapshots, and hit
testing. Read it before changing `src/document/`, `src/browser/render/`, frame
display lists, or DOM-backed interaction state.

## DOM and source buffers

Most parser-created tag names, DOM text, undecoded attribute values, CSS names,
and CSS values are borrowed slices. Attribute values containing supported
character references move into `Element.owned_strings`; DOM text stays
source-backed and escaped because layout decodes it exactly once. Text's
`character_references` flag distinguishes this representation from literal
XML/script data independently of `owned_text`; DOM readback decodes only the
former. Normalized fragment RCDATA can own encoded bytes. Script-created or
mutated non-ASCII Text additionally owns `utf16_data`, preserving lone surrogates
and UTF-16 offsets without feeding invalid UTF-8 to native rendering. Its `text`
bytes are a scalar projection (unpaired surrogates become replacement characters
for display). Both allocations move with the Text and retire together. DOM
readback copies the authoritative units into traced Kiesel storage; element
textContent concatenates DOMStrings without a lossy UTF-8 round trip. Preserve:

- A navigated Frame owns parser input through `html_source.Store`. Its initial
  decoded response and any future parser-inserted chunks are independently
  allocated, append-only source segments. Retire the DOM before clearing the
  store; never resize or replace a segment that an Element/Text slice borrows.
- A detached `DOMParser` result owns a duplicated source buffer in its
  `WindowRealm.detached_sources` list. Both the HTML tree builder and the
  bounded XML tree builder borrow that buffer, so detached nodes are retired
  before the source list is cleared with the Realm.
- Dynamic HTML fragments also retain their duplicated source in that Realm
  list. Children transferred out of a temporary parsing container must not
  borrow its lifetime. `html_fragment.zig` stages source/tree ownership and
  marks scripts inert over `HTMLParser.parseFragment`; it is not a separate
  tokenizer or tree builder.
  This is Realm-lifetime source retention, not per-node garbage collection;
  repeated fragment replacement can retain buffers until Realm retirement.
- `html_live_parser.zig` drives initial navigation directly into the Frame's
  final root slot. It may publish that partial tree to the new document Realm
  at a parser-blocking script boundary, but only through parser-local pins;
  raw child pointers never cross the boundary. The one-shot
  `html_parser_session.zig` remains an inspection/compatibility caller, not
  the navigation owner.

1. decoded HTML until the complete DOM retires;
2. stylesheet text until every rule and keyframe borrowing it retires;
3. Element-owned decoded strings until that Element retires;
4. decoded image data until every display generation borrowing its pixels
   retires.

`Element.attributes` owns an `attributes.Map`: an allocator-bound ordered
index/list with borrowed names/values. HTML parsing preserves the first
duplicate attribute; script replacement keeps the old list position and
ordered deletion followed by reinsertion appends. XML duplicate rejection
remains the XML parser's responsibility. Iterate synchronously and never
retain entry pointers across growth/removal. Existing Element-owned strings
remain retained through Element retirement because styles can still borrow
older attribute values. JavaScript attribute snapshots/readback copy strings
into traced storage before returning; dataset views retain wrappers only.

Live HTML serialization reads the current tree and attributes. Attribute names
are emitted deterministically, values are quoted and escaped, ordinary closing
tags are recursive, void elements omit children and closing tags, and
source-backed DOM text is copied verbatim to avoid double escaping. Literal
script-mutated text is escaped except under raw-text elements. Ordinary,
preformatted, intrinsic-width, and textarea rendering consult the independent
character-reference flag so literal `&amp;` is not decoded again.

CSS `:before`/`:after` nodes are private, heap-stable Nodes owned by their
host Element. They never enter authored child arrays, serialization, ID lookup,
or script-visible DOM traversal; active layout instead injects them in
before/authored/after order. The bounded implementation activates only empty
quoted `content` (`''` or `""`) boxes. Text-bearing generated content remains
deferred until it has an explicit owned-text lifetime and DOM-boundary design.

`inspection.Page.load` returns its root by value. Call
`Page.repairParentPointers` after that root reaches its final address and before
layout or paint performs an ancestry walk.

Raw `HTMLParser.parse` has the same return-by-value boundary: store the root
at its final address and call `fixParentPointers(&root, null)` before style,
invalidation, layout, DOM ancestry, or JavaScript publishes Node pointers.
The parser can only repair its provisional local root before returning it.

## Document module ownership

`src/document/parser.zig` is a compatibility entry point, not a second
document owner. Existing callers import one stable surface while the work is
split across acyclic modules:

- `dom.zig` owns Node/Element/Text storage, private Element-owned generated
  pseudo nodes, Element-backed resources, parent and style-owner rebinding,
  invalidation callbacks, and DOM traversal helpers;
- `html_parser.zig` is a stateful, source-borrowing tokenizer/tree builder
  generic over the DOM types and final parent-pointer repair callback;
- `xml_parser.zig` owns the XML tree builder shared by detached `DOMParser`
  documents and temporary SVG image decoding. Image callers opt into depth and
  element-count limits. It preserves qualified-name case, requires
  quoted attributes, decodes the XML entity subset, and leaves malformed-input
  parser-error construction to the script host boundary;
- `html_source.zig` owns the stable source chunks for one navigated document,
  while `html_tokenizer.zig` borrows append-only chunks and produces owned
  chunk-boundary-independent lexical tokens. `html_live_parser.zig` owns the
  resumable initial-navigation tree build and pauses only at complete classic
  script elements; `html_parser_session.zig` owns a separate one-shot
  compatibility invocation;
- `node_pins.zig` owns parser-local opaque Node pins over the core relocatable
  identity registry. Its Store owns maps and a no-reuse local issuer, not
  Nodes or source chunks; a pin is either rebound synchronously after a move
  or retired before a callback can observe the document;
- `html_serialization.zig` generically serializes the current live tree and
  owns only temporary output/sorting allocations;
- `css_syntax.zig` owns source-buffer scanning for comments, strings, escapes,
  balanced functions, and top-level structural delimiters; it returns only
  borrowed ranges and never decides property grammar or computed values;
- `css_properties.zig` owns the static set of published computed longhands and
  their initial source slices, shared by declaration-name recognition and
  style-map initialization;
- `css_declarations.zig` owns property validation, shorthand expansion and
  declaration-block precedence shared by both CSS syntax frontends. Its maps
  own tables only; names and values borrow their source/normalized-string owner;
- `pseudo.zig` owns only the shared before/after identity used by DOM,
  selector, and style owners; it owns neither a Node nor a stylesheet value;
- `animation.zig` defines pure transition/keyframe interpolation values that
  Elements own, while the serialized Tab animation driver decides which
  render phase each published value dirties;
- `style_application.zig` owns property defaults, cascade, inheritance,
  animation-track updates, and subtree-skipping style traversal behind a
  narrow comptime DOM/callback interface; and
- `style.zig` binds that algorithm to `dom.zig` and publishes the concrete
  style-pass functions re-exported by `parser.zig`.

Focused owners may import their direct leaf dependencies, but must not import
`parser.zig` back through the compatibility surface. Keep the facade
logic-free so DOM storage, parsing, serialization, animation values, and style
application retain unambiguous lifetimes.

CSS declaration parsing must keep escaped delimiters and delimiters inside
strings/functions out of block recovery. Comments are CSS whitespace for
token-based shorthand parsing. The parser validates the supported used-value
grammar before a declaration enters its per-rule cascade map, so an invalid
later value cannot replace a valid earlier supported value. Values and
canonical property names remain static or source-borrowed; no normalized
stylesheet string may outlive the stylesheet generation that supplied it.
At stylesheet top level, invalid qualified-rule starts recover through the
matching block terminator; a stray semicolon is not silently discarded ahead
of a later rule.

Element computed fields contain static defaults or Element-interned strings.
They must survive stylesheet/inline-attribute replacement until the next style
pass compares old and new values. Text inheritance borrows its ancestor's
stable computed storage. Interned values retire with the Element, not after
each style pass; repeated equal values reuse the same allocation.

External CSS rules additionally own their final source URL and retain the
stylesheet's scalar referrer policy. The winning background declaration's
source URL is interned into the Element before rules retire. Resource loading
uses this provenance for relative URL resolution and Referer, while retaining
the containing document's CSP and cookie context; see
[referrer policy](navigation-and-network.md#referrer-policy).

Stylesheet rules carry their cascade origin independently of source ownership.
Browser and isolated inspection mark their default sheet as user-agent rules;
document sheets remain author rules. `presentational_hints.zig` maps supported
HTML table/cell widths, cell `nowrap`, and legacy `align` attributes into
temporary declarations below author rules and above normal UA rules. Winning
hint strings are interned with other computed values before the temporary
arena retires. Legacy alignment has distinct internal values: it aligns block
children as well as lines, unlike ordinary CSS `text-align`. Explicit auto
margins and authored alignment retain precedence.

`custom_properties.zig` owns one immutable, heap-stable computed environment
per styled Element. Inherited entries copy their parent's already-computed
values; local declarations resolve forward references, fallback dependencies,
and cycles after cascade. Ordinary declarations containing `var()` defer
validation, and shorthands publish pending longhands so substitution cannot
change cascade order. Invalid winning substitutions use `unset`, not an older
declaration. Expansion is depth/size bounded. Computed replacement strings are
retained by the Element, independently of the environment's replacement.

`css_value_tokens.zig` scans borrowed tokens without changing strings, comments,
URLs, or identifiers. Style resolves `rem` dimensions against the document
root's computed font size; the root's own font-size uses the initial 16px.
Descendants subscribe to that root field, and computed values consumed by
layout contain pixel dimensions even inside functions. `length.zig` evaluates
bounded typed `calc`, `min`, `max`, and `clamp` expressions with explicit font
and percentage bases. An indefinite percentage basis stays unresolved.
Supported keyframe endpoints undergo variable/rem computation in a temporary
arena before scalar track construction. Their signature includes computed
endpoints, and root-relative tracks subscribe through the Element's animation
field so a root-font change refreshes them without retaining temporary strings.

Custom-property changes publish through a separate heap-stable protected
version field, not additional entries in the fixed StyleMap. Descendants
subscribe to their parent's version so newly introduced names also invalidate
them. Heap storage keeps this publisher stable when its owning Node moves;
structural mutation still clears the graph before moving Node storage.

## Experimental CSS syntax owner

`css_frontend.Syntax` is the source owner behind opt-in Terence inspection.
Interactive Frames, screenshots and WPT adapters retain the legacy parser.
The owner duplicates source and optional serialized base-URL metadata,
owns the Terence AST and diagnostic storage, and releases those borrowers
before their source. The heap holder keeps its budget allocator context stable
when the outer owner moves. Do not shallow-copy it into a second owner.

Node IDs, ranges, views and iterators borrow exactly one immutable syntax
generation. They must retire before successful replacement/deinit; they do not
provide stable CSSOM identity. Raw source ranges preserve escapes and EOF
spelling, rather than representing normalized token values. Its offline
replacement helper requires all external borrowers to retire before success;
consumers with installed styles use staged publication instead.

`css_stylesheet.Sheet` owns that syntax, normalized strings, translated
selectors/declarations/keyframes and parent-linked media conditions. Parsing
adapts these once. `Sheet.select` evaluates retained conditions and returns
independently owned selector/map/URL/frame containers whose declaration strings
borrow the Sheet. Retire every selection before its Sheet. Unknown rules and
CSS nesting remain syntax only; the adapter executes ordinary rules, supported
media conditions and keyframes using Zibra's existing semantics.
Sheet and inline-block budgets cover their retained syntax and semantic
allocations; selections use their caller's allocator and explicit OOM cleanup.

`css_normalize.zig` converts supported identifier/function/unit spellings into
property-grammar inputs without changing token classes or reparsing a sheet.
Its outputs are owned by the Sheet or `DeclarationBlock`; string/URL payloads
retain authored spelling. This is not CSSOM serialization. Both syntax paths
feed `css_declarations.zig`, including declaration-local importance and source
order before shorthand expansion and invalid-value fallback.

`css_inline_styles.Cache` owns copied `DeclarationBlock` inputs for authored
style attributes, deduplicated by text. `styleWithInputs` borrows its provider,
maps and source strings synchronously. A supplied provider must cover every
inline value needing restyling; missing entries fail explicitly rather than
falling back to the legacy parser. Rebuild the cache before styling changed
inline attributes. Computed winners are Element-interned as described above.

An experimental `inspection.Page` owns sheets, their active selections and the
inline cache with its DOM. `reselectMedia` and `replaceStylesheet` require a
final-address DOM and retired layout/display consumers. They stage every
fallible parse/selection allocation before clearing style dependencies,
dirtying the DOM and installing the new generation. Staging failure leaves the
installed rules, media and computed values unchanged. Successful replacement
retires old executable containers before their source Sheet.

Call `Page.restyle` after successful publication and before rebuilding layout
or painting. Restyle is a separate fallible phase: failure preserves the new
valid generation and dirty work for retry, rather than rolling publication
back. Existing computed strings remain valid across source retirement. These
APIs neither schedule Browser frames nor expose a live CSSOM mutation model.

All three syntax entry modes share preflight and allocation limits. They keep
unknown rules and duplicate declarations for later semantic consumers; syntax
acceptance must never imply supported selectors, properties or at-rules.
The CLI enables this path only for style/layout/display-list dumps with
`--css-parser=terence`; the default is `legacy`. Production adoption gates,
verification fixtures and the temporary backend-import bridge are in the
[acceptance decision](../css-frontend-acceptance.md).

## Address-unstable Node storage

Element children are `Node` values in resizable arrays. A child pointer is
valid only until an operation may relocate, reorder, or remove its siblings.
DOM handles, parent pointers, layout back-pointers, frame-element pointers,
focus/hover state, accessibility pointers, and display provenance must be
rebound or retired synchronously when storage changes.

`core/relocatable_identity.zig` supplies the reusable two-way pointer/scalar
registry used for address-unstable identity. It owns neither a Node nor the
scalar issuance policy: a JavaScript host keeps its globally non-reusing
  handle issuer, while a live parser keeps its document-local opaque-pin
issuer. A registry repair transaction reserves before mutation, unpublishes
old pointer keys, and rebinds the same scalar before control can return to
JavaScript or another foreign observer. It is not permission to retain a raw
Node pointer across an asynchronous boundary. Its type-erased
`RelocationObserver` lets the script mutation transaction carry an optional
second scalar identity map without importing parser code; because capacity
growth can already have retired old storage, observer callbacks treat the
provided pointer as an opaque key and never dereference it.

`node_pins.Store` makes that parser policy explicit. It has a local no-reuse
issuer and exposes a pointer-free relocation token; a parser must retire the
token if a script mutation discards the node instead of rebinding it. Pin
resolution is prohibited during the unpublish/rebind gap, and all pins retire
before the source DOM generation does. The Store adapts itself to the core
observer contract, while its Browser/loader caller installs that adapter only
around one direct parser-blocking script evaluation and clears it before the
parser pauses again.

An attached iframe Element carries only a numeric child-window ID. That scalar
moves safely with a Node; it is not proof that the browsing context is live.
Consumers must resolve it against the current Tab registry. A detached iframe
may carry a stale ID.

## Structural mutation transaction

CharacterData writes stage the entire new UTF-16/UTF-8 pair before invoking
this boundary. They preserve every Node address and handle, but conservatively
retire the existing layout/display borrowers before freeing old text slices.
Completion sees the new data and dirty parent style (including `:empty`);
detached writes do not notify the live Frame. This currently uses the full
structural invalidation path, not a retained text-layout optimization.

General structural mutation is a document-generation boundary, not ordinary
style invalidation. Before child storage can move or retire:

1. validate handles, arguments, cycles, and destination identity;
2. reserve or stage every fallible owner needed to finish or recover;
3. mark the Frame document dirty and schedule replacement paint;
4. clear all current computed-style subscriber maps while both endpoints are
   alive;
5. retire the frame display list and DOM-keyed hit, focus, hover, scroll-focus,
   fragment, image-box, accessibility, and compositor borrows;
6. retire active Browser draw/layer/display state under `Browser.lock`;
7. destroy the affected layout dependency graph while its old DOM is alive;
8. mutate the child arrays, repair parents, and rebind surviving handles;
9. run the paired completion callback synchronously so iframe contexts are
   rebound or unloaded before JavaScript resumes;
10. defer network loading for newly attached resources until the host call has
    returned.

Allocation failure after the retirement boundary must still leave a valid
dirty generation that can render again. Focus on a surviving mutation root may
remain; focus on a removed strict descendant must be cleared.

`createElement` returns a window-owned, heap-stable detached root.
`appendChild`, `insertBefore`, and `removeChild` transfer ownership rather than
copying a subtree. `replaceChildren` stages all attached/detached sources and
  runs one mutation transaction. Repeated roots retain only their last
occurrence. A removed subtree with a published JavaScript handle moves to
heap-stable detached ownership; an unobserved removed subtree can be reclaimed.

### Retained insertion exception

An insertion-only mutation may preserve the style dependency graph and
`DocumentLayout` only when the layout owner verifies a one-to-one mapping from
every represented direct DOM child to a DOM-backed block layout. Anonymous
inline runs, run-in merging, style/link-bearing inserts, reorder, or ambiguous
classification use the general transaction. A removal may use the same narrow
boundary only when it removes a newly inserted gap that has no layout owner;
removing an already-laid-out child still uses the general transaction.

The retained path must reserve first, move Nodes, and synchronously rebind both
JavaScript handles and every matched layout `node_ptr` before control escapes.
Layout creates owners only for unmatched insertion gaps. Each block's protected
`previous` field is rewired for its new in-flow predecessor so vertical
invalidation propagates without reallocating unaffected siblings. A retained
gap removal rebinds the surviving direct children after the child array shifts;
it does not destroy or retain the removed subtree's layout.

## ProtectedField and style invalidation

`ProtectedField(T)` is a comptime-generated inline value. Its unmanaged
subscriber table allocates only when a dependency is added. Pass the source
field owner's allocator to `read`/`addDependency` and the same allocator to
`deinit`; do not embed a managed allocator in every property.

Fallible style computation uses `tryAddDependency`: it reserves the publisher
table and allocates the edge before linking either endpoint, and propagates
allocation failure before a frozen read or computed-value publication. This
includes inherited fields, root-relative values and custom-property versions.
The existing non-fallible registration/read APIs retain their best-effort
behavior for older consumers; a fallible style pass must use checked
registration to preserve its retry contract.

A dependency is a source-allocated edge indexed by its publisher and linked
into its subscriber. Destruction unlinks both endpoints: destroying a layout
subscriber removes it from every surviving style publisher, and destroying a
publisher removes its edges from surviving subscribers. Field construction is
allocation-free. Registered fields must remain at stable addresses, including
their reverse-list heads; owner callback rebinding alone does not repair a
moved registered field. Supported structural mutation still clears style
publishers before relocation and forces a complete style/layout rebuild.

`lastValue` is a non-subscribing historical read. It is allowed while dirty for
ordered teardown or an interrupted animation's prior visual value. It is not a
replacement for a successful computation or clean `get`.

Every Element summarizes strict-descendant style work with
`has_dirty_style_descendants`. Explicit selector invalidation and inherited
field notifications raise this bit along the parent chain. Since Nodes move by
value, `fixParentPointers` must also rebind field owner callbacks. Clear a
summary only after all requested child passes succeed; a clean summary permits
the complete subtree to be skipped.

An error keeps the Element summary set even if its own fields were already
published and it has no authored children: ancestry allocation and generated
pseudo creation can still be pending. Failed pseudo styling also dirties the
host's logical child sequence/layout, because partial publication can change
activation before retry records its previous value. Partially computed maps
remain dirty; published strings keep their existing Element ownership.

`:has(...)` matching additionally builds a synchronous ephemeral post-order
cache. It borrows both DOM and selector pointers and cannot cross a DOM or rule
mutation. Selector-relevant mutation dirties the changed element and its
ancestor chain.

Stylesheet selector lists expand into independently owned rules in source
order, with member-specific specificity. Map tables and selector storage are
independent owners; declaration strings continue to borrow the stylesheet.
An invalid member rejects the whole ordinary list before any rule is published.

## Render phases

Each Frame owns a `ProtectedField(?*DocumentLayout)` named `document`.

- A dirty Frame document requests style and prohibits layout/hit-test `get`.
- Successful style and post-cascade resource discovery republishes the same
  optional pointer clean.
- `DocumentLayout.layoutNeeded()` and its descendant graph are then the sole
  geometry dirty source.
- `Tab.needs_paint` is independent and covers paint-only work.
- Compositor-only opacity and translation updates should dirty none of those
  phases.

Do not reintroduce tab-wide `needs_style` or `needs_layout` flags. Teardown may
read the last published document only to destroy it in the correct order.

Rebuilding viewport-dependent stylesheet rules must mark both the DOM style
fields and `Frame.document` dirty. A startup resize can survive navigation and
reach a newly styled Frame; that Frame must re-enter style before layout reads
the rebuilt generation.

`document/media_query.zig` evaluates borrowed conditional preludes without
allocation or retained state. Width, height, color and monochrome support
boolean, colon/min/max, and range comparisons (either operand order and
same-direction chained bounds). Logical conditions support grouped `and`,
`or`, and `not`; unknown features remain unknown under negation, and malformed
top-level queries recover at the next comma. Condition recursion is bounded.
Absolute lengths and em/rem resolve to CSS pixels; media em/rem use the initial
16px font, never the styled root font. Comparisons share the existing small
zoom-normalization tolerance for lengths so equality and strict/inclusive
complements agree. Source-backed rules and keyframes still rebuild as a unit
when either viewport axis or zoom changes. This does not add `matchMedia`,
style/link `media` attribute handling, CSSOM media serialization, or new device
features such as resolution/aspect-ratio; font-metric/viewport units and CSS
math in media values remain unsupported.

Layout fields form dependencies among document, parent, previous sibling, and
child geometry. During one serialized layout traversal, document/block/line
`in_layout` guards suppress only reentrant owner-wide notification caused by a
child metric being recomputed. They do not suppress an external invalidation.

## Layout ownership and geometry

`DocumentLayout`, blocks, lines, and text objects borrow their DOM nodes.
DOM-backed layouts install geometry and paint callbacks plus opaque matching
callbacks on Elements. Clear those callbacks before the layout owner retires.

Important geometry contracts:

- `display:none` suppresses the whole subtree before block classification or
  inline painting, including positioned descendants and interaction bounds.
  Parent tree/line fields stay subscribed to the hidden element's display so
  showing it can rebuild the appropriate formatting context.
- Content-bearing `inline-block` boxes establish an atomic inline participant
  and an independent float context. Their synchronous temporary BlockLayout
  trees handle normal child layout, used box edges, percentage bases, and
  effects. `inline_snapshot.zig` owns the materialized commands and local
  interaction bounds after that tree retires; command provenance and style
  subscriptions target the persistent outer block, including nested atomic
  boxes. Final line placement translates those bounds once. Auto widths use
  bounded intrinsic measurement, including collapsed whitespace across inline
  siblings; baseline alignment uses the last in-flow line or bottom edge.
- CSS font sizes remain pixel em sizes through measurement and rasterization.
  SDL_ttf's default 72-DPI API must not receive a second pixels-to-points
  reduction. Emoji follow the same pixel em size; authored/accessibility zoom
  retain their separate existing roles.
- Block `x`, `y`, `width`, and `height` are used border-box values; CSS width
  and height are content-box inputs unless `box-sizing: border-box` requests
  subtraction of padding/borders before content sizing. Min/max dimensions
  follow the same sizing convention. Per-side box edges are used values too:
  a `none` or `hidden`
  border has zero geometry as well as no paint, while transparent solid
  borders still reserve their resolved width.
- Normal-flow block auto margins distribute remaining space after min/max
  width constraints, including `width:auto; max-width:...` centering.
- A definite parent height, including zero, remains a percentage basis while
  that parent's serialized layout traversal is active. Earlier child
  measurements may dirty its height dependency without making the published
  containing-block height indefinite for later siblings.
- Authored CSS `zoom` is multiplicative and layout-inducing. Fixed lengths,
  fonts, natural replaced sizes, radii, transforms, and filters incorporate
  authored zoom in page coordinates. Accessibility zoom is applied once at
  raster and must not be baked twice.
- The bounded table context recognizes `table`, row/header/footer groups,
  `table-row`, and `table-cell`.
  `layout.zig` keeps real DOM-backed boxes, creates only a synchronous
  normalized row/cell plan, and delegates scalar single-span track math to
  `render/table_format.zig`. Automatic widths use descendant min/max-content
  measurements (including native controls and box edges), with min-content
  floors and percentage-column constraints. Definite columns keep their
  preferred widths when unconstrained columns can absorb surplus space.
  Descendant metric dependencies publish to the persistent table width or the
  containing atomic snapshot's dependency target, never a temporary cell.
  Groups retain their DOM-backed boxes and use the table's shared columns;
  this includes `tbody` inserted by the live parser. Only the synchronous
  measurement plan flattens groups into rows. Header/footer groups currently
  remain in source order, without special reordering or pagination behavior.
  Direct non-row table children occupy anonymous
  row/cell slots without synthetic DOM nodes; whitespace-only anonymous
  blocks do not create slots. Grid children have no normal-flow `previous`
  link, because their positions come from table tracks. Structural mutation
  and display-role changes rebuild table/row children conservatively rather
  than using retained insertion. Inline tables, captions, columns,
  spans, collapse/spacing, and vertical alignment are not part of
  this context.
- Block `flex` and `grid` containers keep DOM-backed item boxes and anonymous
  text runs. Flex sizing supports grow/shrink with min/max freezing, wrapping,
  direction/order, gaps, main-axis auto margins, and basic axis alignment.
  Grid sizing supports fixed, fractional, `minmax`, integer `repeat`, and
  bounded definite-minimum `auto-fill`/`auto-fit` tracks, row-major placement,
  gaps, and basic item alignment. Measurement passes do not publish hit-test
  bounds; only final allocated boxes do. Child topology changes rebuild these
  contexts conservatively. Inline flex/grid, explicit grid placement/spans,
  subgrid, baseline alignment, and complete intrinsic track sizing remain
  outside this bounded implementation.
- A `display: list-item` reserves the browser's bounded marker indent and
  paints its square marker unless the inherited `list-style-type` is `none`.
  The supported `list-style` shorthand currently maps the bounded `disc` and
  `none` values to that longhand; it does not expand into a separate marker
  layout object.
- Float exclusion belongs to the nearest block formatting-context owner.
  Pointer-free float records are rebuilt when that owner lays out; only the
  owner includes floats in auto height. Ordinary normal-flow block border
  boxes retain their containing-block geometry beneath external floats; only
  their inline line ranges are excluded. Floats themselves and bounded
  formatting contexts (non-visible overflow and block table/flex/grid)
  avoid the external float area as whole boxes.
- Direct ordinary block children use a synchronous, pointer-free vertical
  margin cursor. Its pure strut retains the largest positive and most-negative
  adjoining values, allowing sibling chains and fully empty nested blocks to
  collapse without reducing an intermediate chain to one lossy scalar. An
  ordinary border/padding-free parent preflights its first ordinary child and
  folds that child's top margin into the parent's leading strut before either
  box is positioned; the child then begins at the parent's content edge.
  Borders, padding, formatting contexts, inline content, floats, out-of-flow
  positioned children, and child clearance are barriers. When clearance moves a block,
  the complete leading strut is retained before the block is placed below the
  relevant float margin box.
- Relative position preserves the flow slot and stores a separate visual
  offset. Absolute blocks use their layout parent's padding box for used
  dimensions and offsets, have no in-flow predecessor, and do not extend normal
  height. Selecting a more distant positioned containing block through static
  layout wrappers remains a limitation. Fixed blocks use the
  owning frame viewport as their containing block, likewise have no in-flow
  predecessor, and retain an outer `frame_viewport` display-transform wrapper
  so their entire paint subtree ignores document scroll.
- A fixed-height `overflow: scroll` block preserves natural content height as
  DOM scroll geometry, translates only its content, and clips that content.
  `overflow: hidden` uses the same bounded paint and hit-test clip without
  creating element-local scroll state; the present bounded implementation
  clips to the layout block bounds. On the root `html` block it additionally
  suppresses the viewport scrollbar gutter and rail without disabling the
  frame's scroll range; layout resolves that boolean before page geometry and
  commits it as scalar presentation state for browser/raster consumers. The
  Frame retains the last successfully laid-out value, so a post-layout hover
  or DOM invalidation never makes an animation commit read a dirty root style
  map.
- A paint-phase root containing a float or positioned descendant uses the
  bounded phase sequence: negative positioned, static block
  backgrounds/borders, floats, inline/content, positioned auto/zero, then
  positive positioned. It collects participants through ordinary,
  effect-free static wrappers, so a positioned or floating descendant joins
  the nearest phase root instead of being trapped by a non-stacking wrapper.
  Signed z-index and document index order only the negative and positive
  phases. Inline wrappers, tables, clips, scrolling, blends, filters,
  transforms, and positioned subtrees remain atomic. The retained paint order
  records first paint contributions, while structural fallback hit testing
  uses a separate committed content order; exact display command hit testing
  remains authoritative for split overlap.
- Normal inline text collapses ASCII whitespace across nested inline elements;
  `pre` retains line endings and spaces. Temporary embed and rich-button
  layouts must not subscribe short-lived fields to persistent style/layout
  owners. Inline embed metrics are plain scalars because their records move by
  value into growable line buffers; even self-contained dependency edges would
  retain stale field addresses. Their persistent block owns invalidation.

Images and iframes share `render/replaced_sizing.zig` for unscaled CSS used
size. CSS dimensions override matching HTML attributes, a usable aspect ratio
derives only a missing axis, and authored zoom is applied only after both axes
are resolved. Before image pixels exist, every unspecified axis remains zero
unless a preferred ratio can derive it. `object-fit` keeps the element box
separate from the visible bitmap destination and preserves fractional source
crops through clone/snapshot boundaries.

Replaced min/max constraints are resolved before zoom, using independent
containing-block percentage bases. Auto/auto natural dimensions are constrained
together to preserve their ratio where the limits permit it; an authored axis
is clamped before deriving its auto counterpart. Minimums win conflicts.
Border-box limits subtract padding/borders before content sizing. Intrinsic
image measurement uses the same resolver with indefinite percentage bases.
Blockified images paint their allocated content box directly, without an extra
inline strut or duplicate box edges; flex allocations can resize an auto axis
through the ratio. Layout, image hit bounds, and CSSOM use that same box.
Dimension/ratio style dependencies belong to the persistent layout owner, not
temporary image records. Definite containing heights are published before both
block-child and inline-child layout so percentage image limits see a valid base.
Structural inline-ancestor boxes do not establish that height base for a block
image; resolution skips them but stops at a real auto-height block.

Pure layout leaves are intentionally separated from retained object state:

- `render/box_model.zig` resolves box edges, dimensions, positioning values,
  radii, and authored-zoom math after the owning layout object has made any
  dependency-tracked style read;
- `render/border_geometry.zig` derives the outer-to-inner convex mitered
  quadrilateral for one resolved solid-border side. It receives no DOM/style
  pointers: layout resolves per-side style and color, while the display list
  owns the resulting primitive;
- `render/inline_format.zig` normalizes inline text and computes alignment,
  wrapping, line-height, and font-variant used values without walking or
  owning the layout tree;
- `render/table_format.zig` resolves bounded table roles, single-span column
  widths, row heights, and scalar cell rectangles after `layout.zig` has
  normalized the current DOM-backed grid;
- `render/flex_format.zig` and `render/grid_format.zig` solve scalar item and
  track sizing without DOM/layout pointers; `document/css_flex.zig` and
  `document/grid_tracks.zig` own their borrowed CSS grammar;
- `render/intrinsic_width.zig` synchronously borrows DOM and FontManager to
  estimate intrinsic content widths; it retains no DOM or glyph pointers.
  Native input label/size measurement is shared with final control layout.
  Decoded entities, explicit line breaks, `nowrap`, descendant box edges, and
  out-of-flow exclusion participate in the bounded measurement. Inline layout
  preserves `nowrap` across text and atomic boxes. Anonymous inline runs use
  their container's text alignment while keeping dependencies on retained
  layout fields;
- `render/control_geometry.zig` computes control leaf geometry, while the
  `InputLayout` and `ButtonLayout` objects retain DOM/font/collector
  invariants in `layout.zig`;
- `render/layout_hit.zig` performs pointer-free local-coordinate conversion,
  rounded clipping, scroll/transform localization, and reverse-child ordering
  over a synchronous borrow of the committed paint permutation; and
- `render/paint_order.zig` classifies pointer-free direct-child metadata and
  fills stable bounded paint and structural-hit permutations without retaining
  DOM or layout pointers; and
- `render/replaced_paint.zig` constructs background and rounded-control
  command leaves/groups whose pixels and provenance remain borrowed from the
  current generation.

These modules must not register ProtectedField dependencies or acquire
Browser/Frame ownership. Methods that mutate parent/previous links, dirty
state, DOM callbacks, retained caches, or owned child arrays stay beside their
layout objects.

A canvas Element lazily owns a heap-stable backing because z2d Context points
to the embedded Surface. Canvas drawing runs on the serialized tab worker.
Every pixel-changing command dirties the nearest retained paint owner. Paint
copies live canvas pixels into an immutable owning command; committed state
never borrows the mutable backing surface.

## Element geometry snapshots

`render/element_geometry.zig` borrows a clean DocumentLayout synchronously and
returns scalar rectangles and used box metrics, plus a synchronous borrowed
offset-parent Node for the host to convert to a stable handle. Persistent block
border boxes come from protected used geometry; inline fragments are recorded in content order at final line
placement and retained in the owning BlockLayout. Ordinary inline ancestors
coalesce once per line, while the containing block keeps its own border box.
Paint-only regeneration preserves these records instead of appending duplicate
geometry. Hidden/offscreen paint suppression must not erase layout boxes.
Fragments distinguish ordinary inline boxes from atomic/block boxes and retain
used border widths. Client padding sizes subtract these used edges after
layout, and offset positions use the first fragment rather than the union.

Text inputs and textareas share a pointer-free `control_geometry.TextBox`
containing used content dimensions, padding, and borders. Inline controls
resolve sizing and subscribe through the containing block; a block control
uses its allocated content width and paints one shell without an extra inline
line box. The editor clip retains separate client insets: single-line inputs
clip to the content box horizontally and padding box vertically, while
textareas expose the padding box in both axes. These numeric insets travel
with atomic snapshots; borders remain separate for offset-parent origins.
`replaced_paint.appendEditorClip` transfers glyph/caret containers into an
owning raster-and-hit clip, leaving the control shell outside it.

Undecorated empty and collapsible-whitespace-only inline subtrees retain
non-painting line items. Their fragments use the completed line's baseline
and alignment. Trailing collapsed spaces have zero advance; a line containing
only such insertion points is a zero-height phantom line unless a preserved
break ends it. Phantom lines do not establish inline-block baselines. These
items contain no protected fields or owned glyph resources, and paint-only
regeneration never republishes their geometry.

Temporary subtree placement invalidation stops at its persistent containing
block boundary. Recreating an atomic subtree during paint must not mark the
document's retained geometry dirty; live style subscriptions independently
target the persistent outer owner when a real relayout is required.

Atomic inline layout captures its temporary subtree's fragment records into
`inline_snapshot.Snapshot` before retiring the temporary layout. Final line
placement translates those local records into the persistent outer block.
These records borrow Nodes, not layout objects, and retire with their existing
layout/snapshot owner at the structural mutation boundary. No raw pointer
crosses the JavaScript result boundary; `core/rect.zig` supplies only scalar
rectangle math. The host flush/readback contract is in
[JavaScript element geometry](javascript-and-accessibility.md#javascript-element-geometry).

## Retained paint

Document, block, line, and text layout objects own `paint_cache` lists and paint
dirty bits. A dirty leaf transactionally replaces its command buffer.
Ancestors rebuild only shallow ordering/effect wrappers around stable
`.cached_subtree` edges, allowing clean sibling buffers to survive.

When a paint-phase root contains a float or positioned descendant, it may
refresh child caches, synchronously collect phase participants through
ordinary effect-free static wrappers, and emit the bounded phase sequence:
negative positioned, simple static backgrounds/borders, floats,
inline/content, positioned auto/zero, and positive positioned. The collected
participant borrow ends when the cache rebuild ends; retained commands keep no
new layout pointers. Only ordinary effect-free static blocks split across the
background and inline phases. Positioned, clipped, blended, transformed,
scrolling, table, and inline-wrapper subtrees remain atomic; do not split an
effect wrapper merely to improve phase ordering. This is still bounded
phase-root behavior, not full CSS stacking-context ownership.

`.cached_subtree` is deliberately non-owning. It may appear only in a
frame/layout-side list, points to a stable list field on a live layout object,
must be traversed by synchronous readers, and is ignored by recursive cleanup.
Composition and raster snapshots must materialize it into ordinary owned
containers before a Browser lock or thread boundary. Temporary rich-button
trees cannot publish cache edges because their owners retire immediately.
`render/retained_commands.zig` owns this deep-materialization algorithm: it
recursively copies owning command containers and immutable canvas pixels, but
does not own or extend the lifetime of the source layout cache.

`render/paint_effects.zig` owns scalar effect resolution and the construction
of blur, clip (including `overflow: hidden`), blend, transform, position,
fixed-viewport, and scroll command groups. Its
`wrapOwned` boundary consumes the independently owned top-level input slice on
both success and allocation failure. Callers reserve a destination before
transferring returned owning items, so no recursive command is shallow-copied
across a fallible operation.

Solid borders paint as four convex quadrilaterals rather than overlapping
rectangular side strips. Each shape derives its inner corners from all four
resolved widths, so adjacent colors meet on a shared diagonal miter and a
zero-content border box can form triangles. Bounds and painted hit testing use
the quadrilateral rather than treating its bounding rectangle as painted. The
software rasterizer uses hard device-pixel coverage for these integer-rounded
quads: independently antialiasing adjacent source-over fills would otherwise
leave translucent seams at mixed-color or transparent miter joins.

Layout invalidation also dirties paint. Paint invalidation follows layout
ancestry without dirtying geometry. An element-backed block forwards inherited
text paint invalidation to its anonymous inline run. Paint-only regeneration
must not republish content-derived geometry and accidentally leave unprocessed
layout work.

The computed `visibility` property is inherited and paint-only: `hidden` keeps
an element's layout box (and therefore its space and descendants' geometry) but
emits no background, border, or text commands. Paint checks the live DOM node
when a retained layout snapshot may lag a style invalidation, so a visibility
toggle is reflected without rebuilding geometry.

## Display command ownership

`.blend` and `.transform` own their child slices; `.blend` also owns its mode
string. Primitive ownership differs:

- image and glyph commands borrow Element/FontManager pixel owners;
- canvas commands own immutable pixel buffers;
- frame-side provenance and effect nodes borrow DOM/layout identity;
- composited-layer commands borrow live layer allocations.

A Frame's uncomposed list is authoritative for synchronous worker-thread hit
testing and may contain provenance plus a retained root cache edge. Retire it
before rebuilding/destroying layout or DOM. `Tab.composeDisplayList`
materializes cache edges, recursively owns containers, and clears provenance.
`Browser.commit` installs the Browser generation under its lock.

`RasterSnapshot` is the actual worker-transfer boundary. It must deep-copy
every resource-backed leaf, clear DOM/layout provenance, and reject
browser-owned layer pointers. Numeric compositor IDs may cross; raw pointers
may not. Worker jobs, caches, and results use the SMP allocator.

## Compositor and interest-region contracts

Each Browser embeds one retained `display_compositor.Compositor`. It owns the
browser-allocator layer command trees and its derived draw list. A
`DrawCompositedLayer` command borrows an address in the layer array, so the
draw list must retire before any layer is destroyed, rebuilt, or moved. Neither
those raw pointers nor the retained Browser allocator storage cross the raster
worker boundary; `RasterSnapshot` produces the independent worker-owned form.

`software_renderer.Renderer` is the Browser-free interpreter for those owned
commands: primitive drawing, image sampling, opacity/blend/mask/blur effects,
and retained-layer rasterization. A fixed background image retains its
element-local clip rectangle while image tiling uses the current viewport-local
phase. It borrows immutable allocator/I/O choices and the retained compositor's
pure bounds calculator, but owns no SDL handle, thread, or command tree.
Browser and presentation-worker code provide the surface lifetime and explicit
zoom/offset inputs.

Display-command colors and decoded web-image buffers use straight alpha;
z2d source pixels and surfaces use premultiplied alpha. `Color.toZ2dRgba`
converts at every primitive raster boundary, including transformed and layer
paths. Do not premultiply those converted colors twice. Image/glyph sampling
performs its own one-time conversion before source-over; effect surfaces stay
premultiplied throughout composition.

The worker keeps either a bounded assembled page surface or ordered compositor
planes. The interest region is at most four native window heights. A viewport
fully inside the published region can scroll by drawing cached pixels; crossing
an edge, resizing, zooming, replacing the list, or changing geometry requires
a new raster. If the list contains a `frame_viewport` attachment or a fixed
background tile, the worker uses a one-viewport region anchored at the current
scroll offset and does not split compositor planes: only that arrangement
preserves source-order blending and the viewport tile phase. Consequently such
pages re-raster after every root scroll until a future multi-stratum cache
proves the same ordering contract.

Compositor planes own exactly one backing: an RGBA surface or an independent
short pointer-free command snapshot. Short planes are limited to cheap
primitives and replay at draw; glyphs, images, filters, blends, unsafe grouped
opacity, and other expensive commands remain surface-backed. Static merging:

- follows paint order and tight painted bounds;
- stops before a union exceeds the one-megapixel allocation budget, while an
  intrinsically larger single chunk is still allowed;
- promotes a short plane transactionally if it ceases to qualify;
- never moves later paint beneath an actively animated transform, which is an
  assume-overlap barrier for that generation.

Opacity-only ancestry around one `DrawCompositedLayer` folds its alpha into the
draw command. Final draw multiplies that scalar with live layer opacity and
samples the surface once. Masks, filters, blend operators, and multi-command
groups keep their isolation boundary.

## Hit testing and interaction geometry

Painted-command hit testing and structural layout hit testing are
complementary. Command hit testing walks in reverse paint order, inverts
translations, honors clips and rounded corners, treats masks as clipping rather
than targets, and retains exact glyph/fragment geometry. Frame click and hover
resolve viewport-attached and ordinary display commands before falling back to
structural boxes, because one static block can paint its background below a
float and its content above it. Layout hit testing converts the point into
parent-local coordinates while descending; blocks invert live transforms, add
element scroll, apply local clips, and visit children in reverse committed
content order. Do not rebuild absolute rectangles for every descendant. The
committed child permutation is borrowed only for that synchronous traversal;
if its length no longer matches the child set, hit testing safely falls back to
reverse DOM order.

Content clicks require a painted hit but use structural provenance when a
synthetic wrapper has none. Capture stable JavaScript handles before listener
dispatch, then resolve the default action afterward; never retain a raw Node
through script. `stopPropagation` affects ancestor delivery and
`preventDefault` affects the browser action independently.

Mouse hover enters the Tab as scalar coordinates and a pending bit. Resolve it
after any required layout on the serialized worker, then dirty changed hover
branches and ancestor style summaries for a follow-up render. Hover pointers,
focus pointers, element-scroll focus, fragment entries, and accessibility
indexes all borrow exactly one DOM generation.

Focus bounds include every programmatically focusable element. Inline
descendants union into one rectangle per visual line for their nearest
focusable ancestor; a focusable block replaces only its own fragments with one
block box. Focus-ring commands are pointer-free and paint a 4px white outline
beneath a 2px black outline only when `is_focus_visible` is active.

## SVG

Inline SVG is an atomic replaced layout leaf. Its used viewport follows CSS
dimensions, SVG dimension attributes, viewBox ratio, containing-block
percentages, and authored zoom. The HTML parser keeps its authored children in
the ordinary live DOM and honors self-closing SVG shapes. Presentation hints
enter the normal cascade below author rules. Paint reads the resulting live
styles; an Element-owned declaration bitmask distinguishes explicit paint
from inherited paint on use instances and animated ancestors.

The layout leaf borrows its root only within the normal DOM/layout generation.
Each paint invokes `render/svg.zig` synchronously and transfers an independent
straight-alpha RGBA bitmap into an owning canvas display command. Retained
clones and raster snapshots own their pixel copies. A block SVG's outer opacity
is applied by its display-command wrapper; its bitmap omits that outer opacity
to avoid applying it twice. Child attribute/style changes mark the nearest
persistent layout/paint owner through DOM ancestry.
Structural mutation and navigation use the existing borrower retirement order.
No SVG XML tree, ID index, gradient, font buffer, filter surface, or network
response borrow crosses a worker boundary.

SVG image decoding uses the same renderer over a bounded temporary XML tree.
The supported subset is:

- basic shapes, paths, fill/stroke, transforms, nested viewBox mappings, group
  opacity, currentColor and inherited presentation values;
- linear/radial gradients with stops, opacity, object/user units, transforms,
  local href inheritance, and pad extension; local URL fragments are percent
  decoded and a missing paint server may use a solid fallback;
- local use references to shapes/groups/symbols, with instance sizing and
  bounded reference recursion;
- geometric clipPath coverage in user or object-box coordinates, including
  group clips and clip-rule;
- feGaussianBlur (equal x/y deviation), feOffset, feFlood, feColorMatrix
  (matrix/saturate/luminanceToAlpha), feComposite (over/in/out/atop/xor),
  feBlend (normal/multiply/screen/darken/lighten), and feMerge, with named
  results and SourceGraphic/SourceAlpha inputs;
- basic left-to-right text chunks, baseline x/y/dx/dy positioning, font-size,
  solid fill, and nested textual tspan content through z2d TrueType outlines;
- inline external image href resources loaded by the Browser, with meet/none
  fitting and transformed raster sampling;
- clock-based animate, animateTransform and finite-duration set tracks for
  the supported geometry/paint/transform properties, from/to or values,
  linear/discrete interpolation, repeatCount and freeze/remove end behavior.

Element-owned animation samples contain independent strings, not mutations of
authored attributes. The Tab supplies monotonic time, samples on its existing
animation frame chain, and dirties SVG paint (and layout for viewport dimension
tracks). Nested SVG shares its outer root's timeline. DOM-triggered frames
resample completed timelines so removed tracks release their sampled values.
Finite tracks stop requesting frames after publishing their terminal sample;
no SVG timer retains a DOM pointer. Navigation retires the timeline scalars and
samples with the Element.

This is a bounded subset, not general SVG conformance. Masks, markers,
patterns, gradient repeat/reflect, precise nested viewport overflow clipping,
complex text shaping, text anchoring/paths, per-tspan styling/positioning,
font-family/weight selection, cross-root or external use/paint references,
event-based SMIL, keyTimes/splines, additive/motion animation, and animated image
resources remain unsupported. Filter processing currently uses premultiplied
sRGB channels; linearRGB interpolation and primitive subregions/units are not
implemented.
The HTML DOM does not yet implement full SVG namespace/IDL semantics.

Raster limits are 4,096 pixels per axis and 4 Mi pixels per viewport. Reference
collection is bounded to 16,384 elements/128 levels. Drawing permits 64 nested
calls and shares a 65,536-visit budget with object-box traversal. Clip/opacity
layers and filter graphs each cap live storage at 16 Mi pixels; filter graphs
permit 16 primitives. Text chunks are
limited to 8 KiB and font files to 16 MiB. Failed allocation propagates; invalid
or oversized inline SVG produces empty paint. Unsupported rendering subtrees
are inert.

## Destruction order

For a Frame generation, retire in this direction:

```text
Browser render state
  -> composed/browser command lists
  -> frame display list and copied DOM indexes
  -> layout and ProtectedField dependency graph
  -> DOM and Element-owned images/canvases/strings
  -> stylesheet and decoded HTML backing
  -> owning URL
```

The reverse direction constructs borrowers from stable owners. Any new API
that replaces an intermediate owner must retire every downstream borrower
first.
