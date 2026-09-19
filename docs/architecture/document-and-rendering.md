# Document, invalidation, layout, and rendering contracts

This document is authoritative for source-buffer lifetimes, structural DOM
mutation, style/layout invalidation, retained paint, command snapshots, and hit
testing. Read it before changing `src/document/`, `src/browser/render/`, frame
display lists, or DOM-backed interaction state.

## DOM and source buffers

Most parser-created tag names, DOM text and undecoded attribute values are
borrowed slices. Compiled CSS declarations and selector names own their strings.
Attribute values containing supported
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
  balanced blocks/functions, and top-level structural delimiters; it returns only
  borrowed ranges and never decides property grammar or computed values;
- `css_rule_syntax.zig` owns borrowed structural rule/declaration iteration,
  source order, unknown at-rule boundaries and EOF recovery;
- `css_nesting.zig` lowers parent selectors into bounded temporary source;
  `css_math.zig` evaluates typed scalar expressions with caller-supplied units;
- `css_properties.zig` owns the static set of published computed longhands and
  their initial source slices, shared by declaration-name recognition and
  style-map initialization;
- `css_declarations.zig` owns property validation, shorthand expansion and
  declaration-block precedence shared by stylesheet and inline-style parsing.
  Its maps own tables and arenas containing normalized names and values;
- `css_supports.zig` owns bounded feature-query evaluation, using declaration
  validation and a strict selector-admission callback without importing the
  semantic stylesheet parser. Query temporaries retain no DOM or source state;
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

CSS parsing has two distinct stages. `css_rule_syntax.zig` produces borrowed
source ranges for structural rules/declarations using `css_syntax.zig`'s
balanced component scanner. These iterators neither allocate nor evaluate
selectors, property values, media or DOM state. Unknown at-rules remain whole
structural objects; semantic consumers ignore unsupported kinds. Qualified,
media and keyframe blocks can end at EOF. Only outer stylesheet lists ignore
HTML CDO/CDC tokens. A maximum of 64 nested components bounds scanner stack
use; exceeding it discards the incomplete construct and remainder of that
iterator input, leaving already completed entries intact.

`css_tokenizer.zig` supplies the shared allocation-free CSS Syntax token stream.
It preprocesses code points while retaining original UTF-8 byte offsets, decoded
content access, numeric type/sign, hash type, bad-token kinds and EOF closure
state. Unicode ranges require explicit descriptor context.
Comments remain trivia, not synthetic whitespace. `css_syntax.zig` uses these
tokens for structural boundaries; `css_value_tokens.zig` uses them for computed
value operations. Neither owner retains input.

Selector admission and atoms use that same lexer and decoder. Tag/class/ID,
attribute and pseudo names decode after token boundaries are known, so escaped
punctuation is data, and comments alone cannot create descendant combinators.
Selector names and arguments are independently owned. HTML tag/attribute names
fold ASCII case; class/ID/value data retain their case. Existing selector-family
and namespace limits remain separate from lexical escape support.

`css_values.zig` validates component nesting and var() arguments, rejects bad
strings/URLs and unmatched closers, and repairs strings/URLs/blocks at EOF.
Values are bounded to 1 MiB and 64 nested components. Standard values normalize
escapes, numbers, units, strings, URLs and separators; supported primitive
serialization is selected by the property registry after shorthand expansion.
Custom values and pending substitutions preserve spelling, case and interior
trivia. Token boundaries use comments rather than invented whitespace.

`color.zig` owns absolute color grammar and specified/computed serialization.
It covers named/hex/RGB/HSL, HWB, Lab/LCH, Oklab/OKLCH and predefined `color()`
spaces. Modern coordinates retain their tagged space, floating-point components
and missing-component bits separately from the RGBA8 paint projection. Alpha
remains precise through CSSOM; missing components become zero only for absolute
painting. Numbers, percentages, hue units and nested calculations use the shared
tokenizer/math evaluator. Relative-unit expressions stay symbolic until style
supplies the font context and registers dependencies.

`color_space.zig` owns allocation-free transfer functions, XYZ/white-point
adaptation, Lab/Oklab conversion and bounded sRGB gamut mapping. Conversion
preserves extended coordinates until the paint boundary. The renderer still
uses an SDR sRGB RGBA8 framebuffer; wide-gamut colors use CSS Color 4 binary
search with local MINDE, capped at 64 iterations. Non-finite/unrepresentable
transforms fall back to bounded channel clipping without changing CSSOM values.
Rec.2020 uses the draft's display-referred BT.1886 transfer function.
`color_mix.zig` parses borrowed mix operands and normalizes percentages, bounded
to 32 operands per mix and 64 nested colors. `color_interpolation.zig` converts
floating-point coordinates, carries analogous missing components, applies
shorter/longer/increasing/decreasing hue paths and premultiplies non-hue channels
by alpha. Multi-color mixes combine operands in order. The default mix space is
Oklab; explicit supported spaces retain their identity through nested mixing.
Only the paint projection is gamut-mapped. Relative colors, custom profiles and
color-scheme-dependent functions remain unsupported. CSS linear gradients share
the interpolation owner; SVG gradient sampling remains its own consumer.

`css_gradient.zig` parses one linear/repeating-linear background, bounded to
1024 expanded stops/hints, 1 MiB and 64 component levels. It borrows source and
owns only serialized output. Declaration admission, shorthand expansion and
feature queries use this grammar. Font-relative lengths and color operands
compute before inheritance, with dependencies on the element/root font fields;
currentcolor stays symbolic until the receiving element supplies its foreground.
Retained operands keep fractional legacy channels independently of CSSOM text.

`gradient_line.zig` owns an independently allocated slice of used scalar stops.
It resolves angles/corner geometry and percentage positions against the actual
gradient line, expands/fixes stops, applies hints and repeats, and samples the
shared premultiplied interpolation owner. Gradients have no intrinsic size or
ratio: automatic background-size axes independently fill the positioning area.
Paint resolves colors before publication and retains no stylesheet/DOM strings
in the used value. Raster samples device-pixel centers inside the ordinary
background tile/clip, without allocating an element-sized bitmap. Modern
participation defaults to Oklab; legacy-only stops retain sRGB compatibility.
Radial/conic gradients, multiple image layers and image-valued animation are
separate capabilities.

`css_position.zig` owns the single-layer one-to-four-component position grammar,
canonical axis order and used offsets. Parsed offsets borrow the normalized
declaration. Declarations, background shorthand and background painting share
this grammar. Resolution receives the element's unscaled font size, authored
zoom and the positioning-area minus image dimensions. This percentage basis may
be negative; only position callers opt into that behavior in the length context.
Used coordinates saturate to i32 and image clipping/resource lifetimes are
unchanged. Multiple backgrounds and unsupported length units remain separate.

`css_parser.zig` compiles those ranges into rule and declaration owners.
Ordinary selectors use the same bounded, unforgiving
selector-list parser as direct callers; invalid lists cannot consume later
rules. Media selection remains explicit and currently reparses source.
`@supports` uses the same native condition evaluator as `CSS.supports` and
splices active rules/keyframes into authored source order, including nested
media/supports groups. Conditional group recursion is bounded to 64. Inactive
or grammatically invalid conditions publish nothing; allocation failure unwinds
the complete staged generation, including keyframes appended by inner groups.

Feature conditions are bounded to 64 KiB and 64 nested components. The evaluator
checks all lexical structure and boolean operands; invalid outer grammar and
resource limits fail closed while unknown general-enclosed features are false
and can be negated. CSS Syntax EOF closure, trivia and escapes remain token
operations. Declaration queries compile temporary maps through the same grammar
as authored CSS. `selector()` accepts exactly one complex selector and enables
strict admission recursively, so invalid branches of `:is()`/`:where()` cannot
produce false support claims. Ordinary selector-list forgiving behavior is
unchanged. Feature support is independent of current DOM matches, the custom-property environment,
viewport and animation state. Namespace maps,
font queries and stable CSSSupportsRule/CSSStyleSheet identity remain separate.

Style blocks interleave declarations, nested selectors and conditional groups.
The parser flushes declarations around nested rules in authored order. Nested
selectors substitute `:is(parent-list)` for `&`, preserving the maximum parent
specificity without an exponential Cartesian expansion; implicit descendants
and leading combinators use the same parent context. Top-level `&` maps to a
zero-specificity root scope. The temporary lowered source is bounded to 64 KiB;
the compiled selectors and declaration maps are independent owners. Nested
conditional declarations retain their parent selectors, including pseudo boxes.

`css_declarations.zig` handles edge trivia, supported property validation,
shorthand expansion and component-aware priority before emitting into a sink.
The structural ranges preserve authored order/duplicates; compiled stylesheet
maps do not, so they must not be exposed as a retained CSSOM representation.
Both those maps and inline CSSOM blocks use this same declaration grammar.
Formatting/font keyword families and scalar opacity/radius values have explicit
admission; animation admission reuses the playback parser. Remaining legacy
SVG/paint token families need stricter property-specific grammars, so feature
queries are bounded by current native declaration support.

`css_declaration_block.zig` owns a heap-stable ordered longhand index and an
arena containing its source/value strings. Winning authored declarations take
their last winning source position; CSSOM setters replace values/priority in
place, with new longhands appended. Shorthand queries use the shared registry.
Each Element lazily owns its parsed inline block. `attributes.Map.style_revision`
changes on every successful raw style write/removal, including identical text,
and lets `Element.inlineStyle` stage a new block before retiring a stale one.
Other attribute edits leave this owner intact. Attribute entry borrows must not
be used to bypass the map's mutation APIs and revision tracking.

CSSOM mutation clones and edits an unpublished block, then
`Element.replaceInlineStyle` stages the serialized attribute and its owned
strings before publishing both together. Ownership transfers only on success;
the caller dirties style and requests rendering through the synchronous host
mutation hooks. The style pass reads this retained block directly. A partially
overridden `var()` shorthand contains pending longhand substitutions that
serialize as empty CSSOM values: reparsing attribute text cannot retain that
state. Therefore CSSOM commits and DOM clones keep/deep-copy the actual block;
explicit raw attribute replacement reparses it. Blocks move with Elements and
retire with them. They retain no DOM, layout, JavaScript, or stylesheet pointers.

CSS declaration parsing must keep escaped delimiters and delimiters inside
strings, URL tokens and balanced blocks/functions out of recovery. Comments separate tokens without joining their contents. The parser validates the supported used-value
grammar before a declaration enters its per-rule cascade map, so an invalid
later value cannot replace a valid earlier supported value. Compiled declaration maps own an arena for normalized names and values, plus
their hash table. No stored allocator points into the movable arena. Rule-list
and keyframe clones deep-copy declarations, so retiring one cannot invalidate
another. Keyframe names and structural ranges still borrow stylesheet source.
Values selected from temporary substitution maps must be interned/copied before
those maps retire.
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
decodes CSS string escapes before URL resolution and uses this provenance for
relative URL resolution and Referer, while retaining
the containing document's CSP and cookie context; see
[referrer policy](navigation-and-network.md#referrer-policy).

`css_cascade.zig` owns the scalar ordering key: implemented origin/importance
level, inline attachment, layer rank, independent ID/class/type specificity, then rule
source ordinal. Specificity saturates within each count without carrying into
another. Rule arrays remain in source order throughout Browser and inspection
publication; no caller may pre-sort them by specificity. Background URL/referrer
selection uses the same key as declaration selection. Inline attachment beats
all stylesheet specificity at equal origin/importance. Normal UA declarations,
HTML hints, author rules, important author rules and important UA rules occupy
separate levels. Between inline attachment and specificity, normal declarations
compare layer ranks in ascending precedence and important declarations reverse
that order. Unlayered declarations form the implicit last layer. Inline important
declarations still outrank layered author important declarations. User sheets,
rollback keywords and further animation/transition levels remain separate work.

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
and cycles after cascade. References decode escaped custom names without case folding; substitution
retains token boundaries with comment separators and scans each appended chunk
once. Ordinary declarations containing `var()` defer property grammar validation, and shorthands publish pending longhands so substitution cannot
change cascade order. Invalid winning substitutions use `unset`, not an older
declaration. Expansion is depth/size bounded. Computed replacement strings are
retained by the Element, independently of the environment's replacement.

`css_value_tokens.zig` scans borrowed tokens without changing strings, comments,
URLs, or identifiers. Style resolves `rem` dimensions against the document
root's computed font size; the root's own font-size uses the initial 16px.
Descendants subscribe to that root field, and computed values consumed by
layout contain pixel dimensions even inside functions. `css_math.zig` evaluates
bounded typed `calc`, `min`, `max`, `clamp`, `abs` and `sign` expressions for
lengths and supported absolute-color components. Numbers, percentages, lengths and angles remain
distinct unless the caller supplies a percentage hint. Times also retain their
dimension; animation declarations preserve `s`/`ms`, while style computes times
to seconds with the element's font context. An indefinite length
percentage basis stays unresolved. Color channel ranges clamp only after
calculation; missing components retain their modern CSSOM representation.
The same math parser can emit a transient, 512-node `css_math_tree.zig` tree
for specified serialization. It folds constant arithmetic, canonicalizes units,
combines like terms and preserves functions and relative units that still need
context. Excessive serialization trees preserve validated source rather than
truncating it. Modern color channels retain specified calculations and apply
ranges at computation. Nested legacy mix operands retain fractional RGB text
in declaration/computed storage so they do not quantize before mixing. CSSOM
property, shorthand and cssText presentation serializes those operands using
canonical legacy RGB. Cloning copies the retained values, not CSSOM text.
Font-dependent color calculations remain specified until style supplies the
computed font size and registers the dependency. Size-container units need a
layout-aware container contract and are not admitted by guessing a width.
Supported keyframe endpoints undergo variable/rem computation in a temporary
arena before scalar track construction. Their signature includes computed
endpoints, and root-relative tracks subscribe through the Element's animation-name
field so a root-font change refreshes them without retaining temporary strings.

The animation shorthand expands into eight independently cascaded longhands.
Each Element retains one scalar timeline, scalar property templates and its
last sampled progress. Delay, negative delay, fractional/zero iteration counts,
direction and all four fill modes determine whether effective tracks are
published. Missing endpoints use the underlying computed value; important
declarations override animation effects. Underlying fields remain untouched.
Longhand/keyframe changes for the same name resample at the retained elapsed
time; removing/changing the name retires the prior tracks. Paused and completed
fills remain visible without requesting more frames. The Tab worker advances
active timelines and invalidates the appropriate paint or layout owner when
an effect disappears. Color tracks own copied floating-point coordinates and
legacy-space identity, without source or DOM pointers. Legacy endpoint pairs
use premultiplied sRGB; modern participation uses Oklab. CSSOM samples preserve
coordinates and alpha while paint receives straight RGBA8. Playback remains a single, frame-driven animation with
endpoint interpolation; multiple effects, intermediate keyframe segments,
wall-clock timelines, animation events and WAAPI are separate work.

Custom-property changes publish through a separate heap-stable protected
version field, not additional entries in the fixed StyleMap. Descendants
subscribe to their parent's version so newly introduced names also invalidate
them. Heap storage keeps this publisher stable when its owning Node moves;
structural mutation still clears the graph before moving Node storage.

## Retained stylesheet ownership

`css_stylesheet.Sheet` is the source/program owner shared by Browser Frames and
inspection. It copies CSS text, optional serialized base URL and sheet-level
media, plus cascade origin and referrer policy. Construction compiles supported
selector/declaration and keyframe branches once, including inactive `@media`
branches. Media conditions retain source-borrowing queries and parent indices;
`@supports` is evaluated at compile time against static engine capabilities.
Each Sheet also owns a `css_layers.Program`: ordered layer declarations with
decoded, case-sensitive name segments, parent declaration indices and optional
media conditions. Invalid preludes roll back the whole declaration list; names
and conditional queries never borrow movable parser storage.

`SelectionBuilder` appends active sheets in document order and builds independent
`css_layers.Registry` trees for each origin. Named siblings reopen; every
anonymous declaration is unique, including identical cached sheets. Only active
sheet/media/supports branches establish order. Nested layers stay grouped under
their parents, with the parent's own declarations in its implicit last sublayer.
All sheets must register before finalizing ranks: a later sheet can add children
to an earlier layer. Compiled references are sheet-local declaration IDs;
staged references are registry IDs; published rules/keyframes contain only scalar
ranks. The temporary trees copy names and retire before selections. Each append
rolls back cloned rules, keyframes and registry links together on failure.
Keyframe name collisions use normal origin/layer/source order.

`Sheet.select` is the single-sheet convenience wrapper. Document callers use one
builder for the complete generation. The live Browser supplies each current media
attribute; inspection uses the copied option. Conditions are evaluated for an
explicit environment. Selectors/declarations and URL provenance are independent
owners in each selection; keyframe names borrow the Sheet. Retire every selection
before its source. `Selection.appendTo` reserves both destination lists before
moving either container, so allocation failure cannot publish half a selection.
These programs are flattened executable rules, not a lossless authored rule tree
or stable CSSOM identity. They do not preserve declaration duplicates/order for
future stylesheet CSSOM serialization.

`browser/frame_styles.zig` owns attached source provenance: each compiled Sheet
has an ordinal among the generation's style/link elements and the media-attribute
revision used in its selection. It retains no Node pointer. Structural mutation
invalidates that generation before owner ordinals are reused; owner lookup
borrows the attached DOM only synchronously. Media changes stage a complete
selection and revision list, then publish both together. Failed selection leaves
installed rules and source revisions unchanged. `Frame.renderStyle` checks
attribute revisions inside the protected style phase, including synchronous
computed-style/geometry reads. Media-only changes fetch no stylesheet resources.

`inspection.Page` owns these sheets, their active selections and its DOM.
`reselectMedia` and `replaceStylesheet` require a final-address DOM and retired
layout/display consumers. They stage every fallible compilation/selection allocation
before clearing style dependencies, dirtying the DOM and installing the new
generation. Staging failure leaves installed rules, media and computed values
unchanged. Replacement retires old executable containers before their source.

Call `Page.restyle` after publication and before rebuilding layout or painting.
Restyle is separately fallible: failure preserves the new generation and dirty
work for retry. Existing computed strings remain valid across source retirement.
Inline declarations are parsed from current attributes by the ordinary style
pass. These APIs neither schedule Browser frames nor expose live CSSOM objects.
The document tests exercise publication failures, source retirement, retrying
restyle, inherited dependencies and generated boxes; the render test checks
geometry, paint and software pixels across replacement and viewport changes.

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

`selector.LogicalSelector` owns complete complex argument lists for `:is()`,
`:where()` and `:not()`. Forgiving is/where lists discard invalid members;
negation and ordinary lists reject them. Specificity uses the maximum valid
argument for is/not and zero for where. Generated before/after selectors apply
logical conditions to the authored host with the host's own ancestors.
`css_anb.zig` shares token-based nth admission and matching, with i64 coefficients
and widened matching arithmetic. Unsupported nth `of` lists are rejected.

Logical matching propagates both ancestry and `MatchContext` through every
compound. An internal borrowed ancestry view wraps caller root-to-parent slices
or stack links during descendant recursion; links never enter a cache or outlive
the matching call. Public callers retain the slice-based matching API.
`:has(...)` matching additionally builds a synchronous ephemeral post-order
cache. It borrows both DOM and selector pointers and cannot cross a DOM or rule
mutation. The styled tree root carries `SelectorDependencies` for its current
rule generation, including unmatched logical branches. A style pass rebuilds
this scalar summary before matching. Selector-relevant mutation dirties the
changed element and ancestors; ancestor-sensitive rules also dirty descendants,
and sibling-sensitive rules dirty the parent subtree. Sheets combining `:has`
with either relationship conservatively dirty the entire tree. Simple selectors
preserve clean sibling skipping. This is a conservative correctness boundary;
no per-selector dependency index is installed yet.

Stylesheet selector lists expand into independently owned rules in source
order, with member-specific specificity. Map tables and selector storage are
independent owners; compiled declarations own their normalized strings.
An invalid member rejects the whole ordinary list before any rule is published.

`color.zig` owns all 148 named sRGB colors, transparent, absolute color-space
parsing and synchronous currentcolor resolution. The style map stores the
resolved inherited foreground for `color: currentcolor` and registers the
ordinary checked parent dependency, including currentcolor nested in a mix.
Other color longhands keep currentcolor symbolic, including when inherited
explicitly or nested in a mix, so paint and CSSOM resolve it
against the receiving element's foreground. Declaration blocks keep their
specified keyword spelling. Font-dependent operands and mix percentages compute
before inheritance, without resolving symbolic currentcolor against the parent.
Keyframe mixtures resolve with the animated element's foreground and subscribe
to the relevant color/font fields before creating scalar tracks.
CSSOM copies serialized colors with alpha precision;
paint projects them to RGBA8 before accessibility remapping and composition.
Root/body canvas-background selection tests CSS alpha before RGBA8 rounding,
so transparent colors allow body propagation while tiny nonzero alpha does not.
Color-only restyling invalidates retained paint without rebuilding clean geometry.

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
complements agree. Retained rules and keyframes reselect as a unit when either viewport axis or zoom
changes. Style/link media attributes use the same evaluator, with an absent or
empty media list matching all environments. This does not add `matchMedia`,
CSSOM media serialization, or new device features such as resolution/aspect-ratio;
font-metric/viewport units and CSS math in media values remain unsupported.

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
  direction/order, gaps, automatic minima, both axes' auto margins, and
  positional/distribution alignment. Grid sizing supports fixed, intrinsic,
  fractional, `minmax`, `fit-content()`, integer `repeat`, and
  bounded definite-minimum `auto-fill`/`auto-fit` tracks, row-major placement,
  gaps, and item/track alignment. Measurement passes do not publish hit-test
  bounds; only final allocated boxes do. Child topology changes rebuild these
  contexts conservatively. Inline flex/grid, explicit grid placement/spans,
  subgrid, general writing modes/RTL, and complete nested flex/grid intrinsic
  algorithms remain outside this bounded implementation. The shared sizing
  contract below defines the supported row baseline groups and percentage bases.
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
  formatting contexts (a used scrollable overflow axis and block table/flex/grid)
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
- Sticky blocks preserve their normal-flow slot and retain only a visual
  offset. `sticky_position.zig` computes each axis from the nearest scrollport,
  insets, containing box and effective margins, including oversized boxes.
  `DocumentLayout.updateSticky` traverses clean layout in parent order and
  includes ancestor sticky movement and element scroll offsets. It dirties
  changed paint wrappers, leaving normal-flow ProtectedFields clean. The Tab
  worker refreshes before the render gate; layout/paint and script geometry
  also refresh before consumption. Native UI/raster threads receive ordinary
  numeric transforms and never mutate sticky DOM/layout state. Retained block
  boxes support both physical axes in horizontal LTR layout; fragmented and
  temporary atomic-inline sticky boxes need a retained constraint contract.
- Physical overflow axes preserve independent clipping, scroll permission and
  reported dimensions. Layout publishes used policy and scroll geometry;
  content-only paint/hit clips and browser viewport policy consume that same
  clean generation. See the overflow contract below.
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

Ordinary in-flow `block` and `list-item` boxes transfer a definite height to an
auto width, or their resolved width to an auto height, through `aspect-ratio`.
`document/css_aspect_ratio.zig` owns the shared scalar grammar and serialization;
`box_model.ratioDimension` transfers dimensions without retaining DOM state.
Derived axes are capped at 2^24 layout pixels to retain coordinate headroom.
Layout registers the ratio read on its persistent geometry owner and publishes
the resulting definite height before percentage-height children are laid out.
The ratio respects `box-sizing`; `auto <ratio>` uses the content box. Explicit
axes and min/max constraints remain authoritative. `min-height` defaults to
`auto`: visible content can enlarge the ratio-dependent height, while an explicit
minimum or scroll container disables that automatic content minimum.
Ordinary-flow intrinsic-width content minimums, cross-axis min/max transfer,
non-horizontal writing modes and positioned ratio sizing remain outside this
slice. The shared sizing contract below covers supported flex/grid transfers.

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
  track sizing, including intrinsic constraints, without DOM/layout pointers;
  `document/css_display.zig` separates inner formatting from outer block or
  atomic-inline participation; `document/css_flex.zig` and
  `document/grid_tracks.zig` own their borrowed CSS grammar;
- `render/sizing.zig` owns scalar content/border-box conversion, intrinsic
  fit-content clamping, constraints and automatic-minimum suggestions;
  `render/box_alignment.zig` owns positional/distribution offsets, automatic
  margins and local baseline groups. `document/css_sizing.zig` and
  `document/css_alignment.zig` provide shared declaration/layout grammar;
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
  current generation. Layout passes already-scaled used border and padding widths;
  `background-origin` selects the border, padding or content positioning box
  for bitmap and generated images. Percent sizes and positions use that box,
  while the paint clip remains the border box. Fixed backgrounds ignore origin
  and retain viewport positioning. Style changes invalidate retained paint
  without invalidating geometry. CSSOM preserves origin lists; the single image
  layer uses their first entry. Background shorthand resets origin but still
  rejects box keywords because their coupled background-clip behavior is not
  implemented. Root/body canvas propagation and native button box modeling
  retain their existing limitations.

These modules must not register ProtectedField dependencies or acquire
Browser/Frame ownership. Methods that mutate parent/previous links, dirty
state, DOM callbacks, retained caches, or owned child arrays stay beside their
layout objects.

### Shared sizing and alignment

The [initial design](../plans/shared-sizing-alignment.md) and reviewed
[nested formatting follow-up](../plans/shared-sizing-alignment-followup.md)
record the bounded capability and its verification. This section is the
authoritative lifetime and used-value contract.

Intrinsic measurements borrow the styled DOM and FontManager synchronously.
`intrinsic_width.measureContent` returns root natural content widths, excluding
that root's preferred/min/max sizing and edges; descendants contribute their
constrained outer widths. `keywordContent` transfers a definite nonreplaced
height through its preferred ratio for intrinsic width keywords, respecting
height constraints and the selected sizing box. Keep this pair separate from
the raw root content suggestion used by automatic minima. `measure` applies
that transfer and root preferred/min/max sizing and returns content widths;
`measureOuter` adds root padding, borders and margins exactly once. Their scale
already includes the root's authored zoom. Descendant zoom is applied when
traversing that descendant. Intrinsic height percentages normally remain
unresolved; the explicit row-flex cross-height exception below supplies a
definite basis without inspecting an outside containing block.
Images retain the replaced resolver's ratio-aware constrained contribution;
flex automatic minima must distinguish that contribution from the raw
natural-image content suggestion. Native control natural widths remain shared
with final layout.

Flex and grid intrinsic traversal follows the same direct-item topology as
final layout: active private generated children surround authored children,
consecutive text nodes form anonymous items, and hidden/out-of-flow children
do not contribute. Direct inline elements are blockified for item sizing while
retaining their inner formatting kind. Root edges and each descendant's zoom
are counted once. Temporary measurement vectors own scalar contributions and
are freed before returning; no layout object or dependency graph is created.
Row flex measurements distinguish wrapping minima from an unlimited line,
including gaps, bases, grow/shrink participation and min/max constraints.
Intrinsic scalar items preserve whether their numeric basis came from content,
an intrinsic keyword or an unresolved percentage. Such a fallback must not
freeze a contribution at max-content solely because grow/shrink is zero.
Definite bases, including a definite preferred width or an actual cross-size
ratio transfer, keep the normal basis limits. This provenance does not make a
final allocated height definite.
Column inline measurement uses cross contributions; intrinsic widths of
height-constrained wrapping columns remain limited. Grid min-content and
max-content constraints use separate track passes with single-span row-major
contributions, including explicit empty tracks and the implicit column policy.
`grid-auto-columns` and `grid-auto-rows` admit one track sizing function each;
cycling a list of implicit track sizes remains outside this bounded topology.
Intrinsic percentages have no invented containing basis; percentage gaps
contribute zero until final allocation.

A row flex container with a resolvable authored height supplies its own content
height as the intrinsic cross-axis percentage basis for direct items. Resolve
that height and min/max bounds without an external percentage base, subtract
border/padding according to box-sizing, and convert page units through each
child's scale. Preserve definite zero; an auto height, unresolved percentage,
or minimum alone supplies no basis. Grid areas and height-constrained column
wrapping do not use this exception. A ratio item's auto-width intrinsic
contribution can use this resolved cross size while its automatic-minimum
content suggestion stays raw. Authored preferred widths and min/max constraints
remain separate. This is a direct authored-size transfer, not a cyclic solver.

Before intrinsic traversal, layout subscribes its persistent owner to descendant
metric styles. A temporary atomic tree routes those subscriptions through its
persistent dependency target. Flex/grid containers also subscribe to item
inputs because one item's contribution changes sibling allocation. Style
subscriptions use the publishing StyleMap allocator; scalar solvers never
register dependencies. Structural mutation retires all these borrows through
the existing layout boundary.

Intrinsic subscriptions include flex/grid tracks, gaps, basis, factors, order,
alignment and active generated descendants. Floated flex/grid containers select
auto width through the same intrinsic fit-content and constraint policy; the
legacy float fallback cannot clamp them below their intrinsic minimum.

Every direct flex/grid item establishes an independent float context. Its
existing float buffer belongs to the retained item and resets for each
measurement or final layout pass; floated descendants contribute to that
item's natural height without affecting a sibling. Determine this boundary
from the persistent parent formatting kind, including during paint queries,
not from the temporary presence of an allocated box.

Preferred/min/max inline sizes preserve `min-content`, `max-content` and
`fit-content` until layout. Intrinsic keywords denote content widths regardless
of box-sizing; numeric border-box values subtract their own padding/borders.
Percentage padding uses the original containing block, before fit-content
available space is calculated. Minimum wins a conflicting maximum, and a
border box never becomes smaller than its padding/borders. `min-width:auto`
is the initial value: ordinary blocks use zero, while flex/grid select their
format-specific automatic minimum. Margin is outside every sizing box.
Scalar arithmetic uses page-layout units; allocation rounds shared edges and
accessibility zoom remains outside layout.

An `AllocatedBox` separates a forced border-box height from `height_definite`.
The former is geometry; the latter authorizes percentage-height descendants.
Original containing dimensions separately resolve the allocated item's own
percentages. Publish definite content height, including zero, before descendant
layout; an earlier child's dirty height publisher does not revoke that base
during the serialized traversal. A nested formatting context must preserve the
same distinction between available numeric space and a definite percentage
basis. Authored heights and resolvable percentages are definite; content-derived
nonstretched flex heights remain indefinite. Flex post-flex main sizes become
definite when the container main size or item basis is definite. Final stretched
cross sizes become definite for descendant relayout even in auto-height lines.
Final grid-area dimensions are definite for item layout; unresolved row
measurement uses no substitute container-height basis. The nonstretched item's
own auto height can still be indefinite. Table allocation retains its existing
separate row/cell policy.

Flex targets include border/padding, but scaled shrink weights use the inner
flex base. Content and specified-size suggestions are separate: `flex-basis:
content` ignores the preferred main size, and automatic minima use the relevant
content, specified and ratio-transfer suggestions before the main maximum cap.
An explicit zero minimum or supported scrollable overflow permits shrinking
below the automatic content floor. Grid automatic minima require a track with
an auto minimum; fixed minima and `minmax(0,1fr)` do not inherit a flex content
floor. Grid solvers receive separate minimum, min-content and max-content
contributions and distinguish intrinsic growth from stretching auto maxima.
A fixed grid-track maximum also caps the item's automatic content minimum;
explicit item minima and tracks with a min-content minimum retain their floors.

Simple flex/grid ratio transfer preserves the same content-box versus border-box
policy. A definite cross size can supply an automatic flex basis; cross-axis
min/max constraints bound the content and transferred automatic-minimum
suggestions. An intrinsic width keyword alone does not make that cross size
definite. Row flex items derive an automatic cross height from the allocated
main width, apply cross min/max constraints and preserve the nonreplaced
automatic content floor. The resulting definite height is published before
percentage descendants are laid out. Grid ratio items derive an automatic width
from a definite height and an automatic height from their resolved width. Row
measurement includes the ratio height before track allocation, and a height
derived from definite width
provides a percentage-height basis to descendants. Grid `normal` preserves these
preferred dimensions while explicit stretch follows the area allocation policy.

Alignment consumes remaining margin-box space after sizing. Safe/unsafe values
and multi-token baseline/place-* grammar remain distinct through declaration
admission. Positive auto-margin space takes precedence over alignment. Flex
cross-axis auto margins also suppress self-alignment when overflowing; grid
overflow auto margins become zero and self-alignment still applies. Auto margins
suppress stretch. Nonstretch auto grid widths use fit-content sizing, specified
widths may overflow their area, and grid `normal` treats replaced/ratio boxes
separately from explicit `stretch`. Track distribution moves grid lines without
changing authored gap values.

Row flex and grid-row first/last baseline groups consume scalar offsets from
the item border-box origin. Retained first/last line metrics are recomputed on
relayout; exporting them subtracts the item's current origin. Ordinary block
export ignores out-of-flow and float descendants and synthesizes a bottom-edge
baseline when none applies. Baseline groups include margins and can enlarge
natural line/row heights. No group retains a line pointer, and measurement
passes publish no interaction bounds. Paint-only work reuses clean metrics.

Formatting containers publish absolute first/last baseline scalars after final
item placement. Flex chooses the physical start/end line and applicable group
or order-modified item, taking reverse and wrap-reverse into account. Grid
chooses the first/last occupied row. Contributor metrics are read at initial
scroll position. Enclosing flex/grid groups convert these scalars to local
offsets; empty containers synthesize a border-edge baseline. Atomic inline-flex
and inline-grid export their first set, including with hidden overflow, while
ordinary inline-blocks retain their last-line/visible-overflow rule.

Inline-flex and inline-grid share the existing temporary atomic layout and
`inline_snapshot.Snapshot` owner. Final inner layout receives the selected
width and original percentage context. Geometry, commands and interaction
bounds are captured and rebound before temporary layouts retire. The
surrounding inline flow's whitespace policy controls wrapping of the atomic
box; the child's own whitespace policy controls its internal content.
The line includes both the ascent and descent of every baseline-aligned item,
adjusted by any vertical offset. A tall atomic box's first baseline must not
discard the extent below it or allow the following block to overlap.
Admitted vertical offsets use signed length resolution and the item's authored
zoom when converted into page coordinates.

This remains horizontal layout with existing row/column reverse and wrapping.
Intrinsic block-axis keywords, width `fit-content(<length-percentage>)`, full
column/orthogonal baseline sharing and complete cyclic intrinsic track sizing
remain separate capabilities. Complete nested flex/grid intrinsic ratio contributions,
orthogonal ratio transfer and general cyclic ratio/percentage resolution also
remain limited. Table-specific content floors and replaced ratio resolution
remain separate policies over the common measurements.

A canvas Element lazily owns a heap-stable backing because z2d Context points
to the embedded Surface. Canvas drawing runs on the serialized tab worker.
Every pixel-changing command dirties the nearest retained paint owner. Paint
copies live canvas pixels into an immutable owning command; committed state
never borrows the mutable backing surface.

## Overflow policy, geometry and clipping

`document/css_overflow.zig` owns physical overflow grammar and pointer-free
`Value`/`Pair` policy. The computed registry contains `overflow-x` and
`overflow-y`; `overflow` is a real shorthand shared by stylesheet declarations,
inline CSSOM and computed shorthand serialization. `overlay` canonicalizes to
`auto`. After substitution and CSS-wide resolution, `style_application.zig`
computes the pair once from the current winning specified values, then publishes
both protected fields. It never reuses the previous pass's coerced pair as
specified input. The current CSS Overflow draft preserves `clip` beside a
scrollable value; only `visible` becomes `auto`. Changing one axis can therefore
change both computed fields.

The style pair and layout's used pair are distinct. Automatic flex/grid minima
use the computed value in the relevant axis, even without actual overflow;
flex chooses its main axis and grid retains its existing track eligibility
rules. Persistent intrinsic/formatting owners subscribe to both fields.
Float/BFC policy asks whether either used axis is scrollable. `clip visible`
does not establish a BFC but does remain an atomic paint subtree. Ordinary
inline-block baseline policy and first/last flex/grid baseline exports retain
their separate rules; a current scroll offset never changes the exported
initial-position baseline.

`Element.used_overflow` is optional scalar layout output. Layout publishes it
with both client and content dimensions through `setScrollGeometry`; no CSSOM
computed field is overwritten. The root/body viewport donor publishes a local
visible pair. Paint consumes this used pair, falling back to computed style only
when no layout policy has been published, as in direct effect tests. It never
walks the DOM to select a viewport donor. New layout refreshes the policy before
paint; no used-policy borrow crosses a generation or thread boundary.

`Layout.publish_scroll_geometry` separates measurement from publication.
Preliminary flex/grid allocations suppress Element policy/geometry publication
and offset clamps, with that suppression inherited recursively by nested and
atomic formatting. They still compute scalar overflow bounds. Final allocations
restore publication, so a temporary natural height cannot erase a scroll offset
before the actual scrollport is known. Temporary atomic-tree retirement does
not clear the live Element's scalar scroll state.

Element scroll metrics and offsets are authored-zoom-scaled layout pixels.
Visible and clipped axes still retain their client and overflow dimensions.
Programmatic maxima are zero on visible/clip axes; hidden/scroll/auto axes can
scroll even when user interaction is disabled. `scroll_user_x/y` separately
record scroll/auto eligibility and visibility. Publishing new geometry clamps
each offset independently, resetting a newly forbidden axis without destroying
the other offset or the reported overflow. User methods select one axis;
programmatic `scrollTo` selects both. Browser adapters refresh sticky state and
paint after movement. Layout publication must also reflect any offset clamp in
the resulting paint/sticky state.
The style publisher also refreshes user permission from the retained used pair
after visibility changes, which may require only paint. Hiding/showing a box
updates wheel eligibility without requiring reflow or resetting its offsets.

`render/overflow_geometry.zig` owns pointer-free bounds operations; retained
layout owns the synchronous traversal. Each block retains local scrollable
overflow and inline-run bounds. Child borders contribute to the parent's
extent, but descendant overflow propagates only through that child's visible
axes. Include existing inline content, flex/grid margins, padding and supported
position/translation offsets; exclude fixed viewport descendants and ink-only
effects. Saturate scalar arithmetic and retain the existing nonnegative LTR
scroll-origin model. Atomic-inline measurement captures separate propagated
overflow bounds before its temporary root retires. CSSOM fragment rectangles
stay unclipped and must not be reused as those propagation bounds.
For ordinary children, document roots and atomic roots, union the bounds before
and after the supported translation: transforms may enlarge scrollable overflow
but cannot shrink it. Authored `transform` field changes subscribe through the
persistent block geometry owner so those extents are refreshed. Compositor-only
animation sampling remains a scalar presentation path and does not republish
computed fields or trigger that authored-style dependency.

`DocumentLayout` retains only the generation-bound root/body donor identity and
numeric content/scrollport extents. Root overflow propagates to the viewport;
when both root axes are visible, the first direct body may donate if it has a
box. A hidden first body does not make a later body eligible. The selected
donor's computed pair remains unchanged. Viewport visible/clip values become
auto/hidden, respectively. Resolve this choice during clean style/layout before
gutter reservation and document geometry, and publish copied scalar policy to
Frame. Frame/Browser commits use the last successful policy even if hover or a
later mutation has already dirtied live style. Existing flow dimensions remain
separate from document overflow dimensions and viewport scrollport dimensions.

Overflow clipping belongs to the translated content suffix. The element's own
background and border remain stationary and outside its padding-box content
clip; whole-element opacity, filters, positioning and transforms enclose both.
The content-only blend carries a pointer-free axis clip shared by software
raster and command hits. Active axes constrain finite child/raster bounds;
inactive axes never create giant sentinel rectangles or element-sized limits
on visible overflow. Single-axis clip/visible geometry is unrounded, while
dual-axis clipping uses the supported padding-edge corner geometry. Layout
hits preserve own border-box targets even when the point cannot descend past
the content clip. Both hit paths remove position/transform, test the clip and
then account for the content scroll translation in the same order.

Retained command clones, temporary atomic snapshots, iframe composition,
raster snapshots and compositor bounds preserve the clip scalars. None retain
new DOM/layout pointers. `wrapOwned` consumes its independent command slice on
success or failure; suffix wrappers preserve the caller's list on allocation
failure. Masks and clips are not hit targets. Existing rounded-control hit
metadata remains distinct from overflow clips.

The supported subset is physical axes in horizontal LTR layout, including
existing Element scrolling APIs and two-axis wheel input. Logical axes,
negative/reversed scroll origins, clip-margin, containment, new Window scroll
APIs, scrollIntoView and new scrollbar widgets remain outside this contract.
Fixed root groups cancel both viewport offsets and child-frame groups use
their own viewport; arbitrary positioned-descendant escape through ancestor
clip/effect wrappers remains bounded by the existing containing-block model.
Rebased child fixed transforms retain optional scalar `translation_origin`
metadata; `scaledTranslation` cancels the iframe origin and child scroll before
the consumer's pixel rounding, preventing jitter at fractional zoom. Clones and
worker snapshots preserve this metadata, and Frame keeps child viewport hit
coordinates separate from rounded page coordinates.
Raster plane extraction declines transforms carrying this origin metadata;
they remain on the assembled rendering path.
Viewport x transport and raster acceptance follow the browser/thread contracts;
an x change rerasterizes the viewport-width surface without introducing a 2D
interest-region cache.

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

`Metrics.has_box` distinguishes a missing ordinary layout box from a zero-size
box. After the normal generation-checked flush, ordinary elements without a box
expose zero scroll metrics and ignore scroll setters; detached handles likewise
resolve to no attached target. The document root retains its CSSOM viewport
special case even when it has no principal box. Do not clear Element scroll
state merely to enforce these query results: temporary formatting and snapshot
owners can retire while the live DOM state must survive.

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
recursively copies owning command containers, gradient stops and immutable canvas pixels, but
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

- bitmap image and glyph commands borrow Element/FontManager pixel owners;
- generated image commands own a scalar gradient-stop slice and no pixel buffer;
- canvas commands own immutable pixel buffers;
- frame-side provenance and effect nodes borrow DOM/layout identity;
- composited-layer commands borrow live layer allocations.

A Frame's uncomposed list is authoritative for synchronous worker-thread hit
testing and may contain provenance plus a retained root cache edge. Retire it
before rebuilding/destroying layout or DOM. `Tab.composeDisplayList`
materializes cache edges, recursively owns containers, and clears provenance.
`Browser.commit` installs the Browser generation under its lock.

Retiring active Browser commands marks the tab as awaiting a replacement
display-list commit. The UI keeps the last completed, independently owned
pixels while the Tab rebuilds; it must not raster the temporary missing list
as an empty page. A scalar-only commit does not finish this wait. An owned
replacement list (including an empty list), tab activation, or closing the
active tab clears it. Borrowed commands still retire synchronously before DOM,
layout, or resource storage can change.

`RasterSnapshot` is the actual worker-transfer boundary. It must deep-copy
every resource-backed leaf, clear DOM/layout provenance, and reject
browser-owned layer pointers. Numeric compositor IDs may cross; raw pointers
may not. Worker jobs, caches, and results use the SMP allocator.
Image command cloning copies any owned gradient stops at retained-tree,
iframe composition, compositor and raster boundaries. Its cleanup frees only
generated data; external bitmap buffers keep their established source owner.
Background image commands carry a scalar corner radius. Bitmap and gradient
sampling share rounded-clip coverage with display masks, preserving previously
painted content without allocating an element-sized clipping surface.

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

## Audio controls

Audio with `controls` is an atomic InputLayout leaf with a 300 by 40 CSS-pixel
natural content box. `render/audio_controls.zig` derives the play, seek, mute,
volume and time rectangles from its used content box and paints from a copied
Element UI snapshot. Audio without controls and fallback descendants do not
participate in layout or intrinsic width.

Full part-background rectangles carry `DisplayItemSource.audio_part` for hit
testing. Decorative commands carry no provenance, so glyphs and slider thumbs
cannot fragment the authoritative slider rectangle. These identities retire
and are cleared from raster snapshots with ordinary DOM provenance. CSS/browser
zoom, clipping and transforms use the ordinary command and hit-test paths.

Progress/volume/play state changes mark retained paint, not layout. Paint reads
the live copied UI snapshot instead of caching playback text during measure.
The Element owns no decoder, voice or asynchronous callback; scalar drag
capture belongs to the Tab. See [audio](audio.md).
