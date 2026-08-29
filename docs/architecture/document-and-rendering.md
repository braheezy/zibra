# Document, invalidation, layout, and rendering contracts

This document is authoritative for source-buffer lifetimes, structural DOM
mutation, style/layout invalidation, retained paint, command snapshots, and hit
testing. Read it before changing `src/document/`, `src/browser/render/`, frame
display lists, or DOM-backed interaction state.

## DOM and source buffers

Most parser-created tag names, DOM text, undecoded attribute values, CSS names,
and CSS values are borrowed slices. Attribute values containing supported
character references move into `Element.owned_strings`; DOM text stays
source-backed and escaped because layout decodes it exactly once. Preserve:

1. decoded HTML until the complete DOM retires;
2. stylesheet text until every rule, keyframe, and computed value borrowing it
   retires;
3. Element-owned decoded strings until that Element retires;
4. decoded image data until every display generation borrowing its pixels
   retires.

Live HTML serialization reads the current tree and attributes. Attribute names
are emitted deterministically, values are quoted and escaped, ordinary closing
tags are recursive, void elements omit children and closing tags, and
source-backed DOM text is copied verbatim to avoid double escaping.

`inspection.Page.load` returns its root by value. Call
`Page.repairParentPointers` after that root reaches its final address and before
layout or paint performs an ancestry walk.

## Address-unstable Node storage

Element children are `Node` values in resizable arrays. A child pointer is
valid only until an operation may relocate, reorder, or remove its siblings.
DOM handles, parent pointers, layout back-pointers, frame-element pointers,
focus/hover state, accessibility pointers, and display provenance must be
rebound or retired synchronously when storage changes.

An attached iframe Element carries only a numeric child-window ID. That scalar
moves safely with a Node; it is not proof that the browsing context is live.
Consumers must resolve it against the current Tab registry. A detached iframe
may carry a stale ID.

## Structural mutation transaction

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
inline runs, run-in merging, style/link-bearing inserts, removal, reorder, or
ambiguous classification use the general transaction.

The retained path must reserve first, move Nodes, and synchronously rebind both
JavaScript handles and every matched layout `node_ptr` before control escapes.
Layout creates owners only for unmatched gaps. Each block's protected
`previous` field is rewired for its new in-flow predecessor so vertical
invalidation propagates without reallocating unaffected siblings.

## ProtectedField and style invalidation

`ProtectedField(T)` is a comptime-generated inline value. Its unmanaged
subscriber table allocates only when a dependency is added. Pass the source
field owner's allocator to `read`/`addDependency` and the same allocator to
`deinit`; do not embed a managed allocator in every property.

A dependency table stores raw subscriber pointers. Field destruction does not
unsubscribe it from its sources. Supported structural mutation therefore
clears all style publishers before destroying or relocating endpoints and
forces a complete style/layout rebuild. General edge-specific unsubscription
remains unresolved.

`lastValue` is a non-subscribing historical read. It is allowed while dirty for
ordered teardown or an interrupted animation's prior visual value. It is not a
replacement for a successful computation or clean `get`.

Every Element summarizes strict-descendant style work with
`has_dirty_style_descendants`. Explicit selector invalidation and inherited
field notifications raise this bit along the parent chain. Since Nodes move by
value, `fixParentPointers` must also rebind field owner callbacks. Clear a
summary only after all requested child passes succeed; a clean summary permits
the complete subtree to be skipped.

`:has(...)` matching additionally builds a synchronous ephemeral post-order
cache. It borrows both DOM and selector pointers and cannot cross a DOM or rule
mutation. Selector-relevant mutation dirties the changed element and its
ancestor chain.

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

Layout fields form dependencies among document, parent, previous sibling, and
child geometry. During one serialized layout traversal, document/block/line
`in_layout` guards suppress only reentrant owner-wide notification caused by a
child metric being recomputed. They do not suppress an external invalidation.

## Layout ownership and geometry

`DocumentLayout`, blocks, lines, and text objects borrow their DOM nodes.
DOM-backed layouts install geometry and paint callbacks plus opaque matching
callbacks on Elements. Clear those callbacks before the layout owner retires.

Important geometry contracts:

- Block `x`, `y`, `width`, and `height` are used border-box values; CSS width
  and height are content-box inputs resolved before/after descendants as
  appropriate.
- Authored CSS `zoom` is multiplicative and layout-inducing. Fixed lengths,
  fonts, natural replaced sizes, radii, transforms, and filters incorporate
  authored zoom in page coordinates. Accessibility zoom is applied once at
  raster and must not be baked twice.
- Float exclusion belongs to the nearest block formatting-context owner.
  Pointer-free float records are rebuilt when that owner lays out; only the
  owner includes floats in auto height.
- Relative position preserves the flow slot and stores a separate visual
  offset. Absolute blocks use the containing block's content box, have no
  in-flow predecessor, and do not extend normal height.
- A fixed-height `overflow: scroll` block preserves natural content height as
  DOM scroll geometry, translates only its content, and clips that content.
- Immediate layout children retain a stable paint permutation ordered by
  effective signed z-index and DOM index. Only non-static positioned blocks
  receive nonzero z-index. Reverse that exact order for hit testing.
- Normal inline text collapses ASCII whitespace across nested inline elements;
  `pre` retains line endings and spaces. Temporary embed and rich-button
  layouts must not subscribe short-lived fields to persistent style/layout
  owners.

Images and iframes share `render/replaced_sizing.zig` for unscaled CSS used
size. CSS dimensions override matching HTML attributes, a usable aspect ratio
derives only a missing axis, and authored zoom is applied only after both axes
are resolved. Before image pixels exist, every unspecified axis remains zero
unless a preferred ratio can derive it. `object-fit` keeps the element box
separate from the visible bitmap destination and preserves fractional source
crops through clone/snapshot boundaries.

A canvas Element lazily owns a heap-stable backing because z2d Context points
to the embedded Surface. Canvas drawing runs on the serialized tab worker.
Every pixel-changing command dirties the nearest retained paint owner. Paint
copies live canvas pixels into an immutable owning command; committed state
never borrows the mutable backing surface.

## Retained paint

Document, block, line, and text layout objects own `paint_cache` lists and paint
dirty bits. A dirty leaf transactionally replaces its command buffer.
Ancestors rebuild only shallow ordering/effect wrappers around stable
`.cached_subtree` edges, allowing clean sibling buffers to survive.

`.cached_subtree` is deliberately non-owning. It may appear only in a
frame/layout-side list, points to a stable list field on a live layout object,
must be traversed by synchronous readers, and is ignored by recursive cleanup.
Composition and raster snapshots must materialize it into ordinary owned
containers before a Browser lock or thread boundary. Temporary rich-button
trees cannot publish cache edges because their owners retire immediately.

Layout invalidation also dirties paint. Paint invalidation follows layout
ancestry without dirtying geometry. An element-backed block forwards inherited
text paint invalidation to its anonymous inline run. Paint-only regeneration
must not republish content-derived geometry and accidentally leave unprocessed
layout work.

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

The worker keeps either a bounded assembled page surface or ordered compositor
planes. The interest region is at most four native window heights. A viewport
fully inside the published region can scroll by drawing cached pixels; crossing
an edge, resizing, zooming, replacing the list, or changing geometry requires
a new raster.

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
than targets, and retains exact glyph/fragment geometry. Layout hit testing
converts the point into parent-local coordinates while descending; blocks
invert live transforms, add element scroll, apply local clips, and visit
children in reverse paint order. Do not rebuild absolute rectangles for every
descendant.

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
