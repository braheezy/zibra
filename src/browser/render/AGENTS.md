# Browser rendering guide

This directory owns layout, font resources, display-command structure,
software effects, retained compositor planes, and worker-transfer snapshots.

Read [document and rendering contracts](../../../docs/architecture/document-and-rendering.md)
before changing DOM/layout borrows, invalidation, retained paint, commands,
hit testing, or raster ownership. Read
[threads and shutdown](../../../docs/architecture/threads-and-shutdown.md)
before changing FontManager concurrency, worker payloads, allocators, or SDL
boundaries.

## Module boundaries

- `layout.zig` owns retained document/block/line/text trees, geometry
  dependencies, hit-test traversal and DOM resolution, focus/image/iframe
  bounds, and retained paint caches. Layout-object methods stay here when they
  maintain parent/previous links, ProtectedField graphs, DOM callbacks, or
  cache dirty state. The module borrows DOM, computed style, decoded images,
  and FontManager resources.
- `layout_hit.zig` owns pointer-free local-coordinate hit geometry: saturating
  coordinate conversion, rounded clips, scroll/transform localization, and
  reverse-child ordering over a synchronously borrowed committed paint
  permutation. It never owns or traverses layout objects.
- `paint_order.zig` owns allocation-free scalar classification and stable
  ordering for the bounded direct-child paint phases. It receives no DOM or
  layout pointers; `layout.zig` retains the phase entries and permutations.
- `box_model.zig` resolves pure CSS box edges, dimensions, positioning
  keywords, radii, and authored-zoom used values. It does not subscribe to
  style fields; `layout.zig` performs dependency-tracked reads before calling
  it.
- `border_geometry.zig` derives pointer-free convex mitered solid-border
  sides from a resolved border box and all four widths. It neither parses
  styles nor owns display commands; `layout.zig` retains those responsibilities.
- `margin_collapse.zig` owns allocation-free adjoining vertical-margin struts.
  It retains the positive and negative extrema of an arbitrary chain; layout
  owns the DOM-backed cursor, clearance barriers, and block geometry that use
  those scalar values.
- `inline_format.zig` owns pure text normalization, entity decoding, line
  alignment/wrapping decisions, and inline font-size used values. Layout-tree
  traversal, glyph ownership, and retained line objects remain in
  `layout.zig`.
- `table_format.zig` owns allocation-free scalar roles and single-span grid
  track math for the bounded CSS table context. `layout.zig` retains all
  DOM-backed boxes and keeps its temporary row/cell plan synchronous; do not
  move DOM pointers, style subscriptions, or anonymous-box lifetime here.
- `flex_format.zig` and `grid_format.zig` own pointer-free item and track
  sizing. `intrinsic_width.zig` synchronously borrows DOM and FontManager for
  bounded intrinsic measurement. None retains DOM/layout/glyph pointers;
  `layout.zig` owns item boxes, subscriptions, and final hit-test collection.
- `control_geometry.zig` computes input/button leaf geometry and password
  display text. `InputLayout` and `ButtonLayout` remain with their DOM, font,
  collector, and display-command invariants in `layout.zig`.
- `inline_snapshot.zig` owns movable atomic-inline paint containers and local
  interaction bounds shared by buttons and inline-blocks. Materialize and
  rebase all commands before retiring the temporary layout tree; nested
  temporary trees subscribe only through the persistent containing block.
- `replaced_paint.zig` appends background-image and rounded-control command
  leaves/groups without owning layout objects. Background attachment selects
  an element-local or viewport-local tile phase while the command rectangle
  remains the element clip. Its image pixels and provenance are still
  generation-scoped borrows until snapshot.
- `paint_effects.zig` resolves scalar block effects from live style and wraps
  owned command slices in blur, clip, blend, transform, position, and scroll
  groups. `wrapOwned` consumes its input slice on every outcome; callers must
  pass an independently owned top-level container.
- `retained_commands.zig` deep-materializes a retained command tree only at a
  boundary that cannot borrow its cache owner. It owns recursive container
  copies and canvas snapshots, but does not own a layout cache.
- `font.zig` owns SDL_ttf handles and canonical allocator-owned RGBA glyph
  bitmaps. Commands borrow glyph pixels only until snapshot.
- `display_list.zig` owns command types, recursive cleanup, provenance,
  painted hit testing, and composited-layer data. It remains independent of
  Browser, SDL, and native-window lifetime.
- `raster_snapshot.zig` is the deep-copy thread boundary. It clears
  provenance, materializes retained cache edges, copies leaf pixels, and
  permits numeric compositor IDs but no DOM/layout pointers.
- `compositor_cache.zig` owns raster-worker planes and pointer-free scalar
  opacity/translation updates.
- `effects.zig` owns pixel-only effects and must state premultiplication,
  sampling, and temporary-allocation behavior explicitly.
- `replaced_sizing.zig`, `focus_ring.zig`, and `forced_colors.zig` are other
  pure focused helpers. Keep Browser orchestration out of all leaf modules.

`layout.zig` is already beyond the repository's decomposition threshold. New
independent formatting, replaced-element, or paint algorithms should become a
cohesive module with a real owner/interface rather than another region in that
file. Do not split methods away from the object invariants they maintain or add
a facade cycle merely to reduce lines. Prefer direct imports of pure leaf
modules over forwarding wrappers.

## Invalidation and layout

- Enter layout only after the owning Frame republishes a clean protected
  document. `DocumentLayout.layoutNeeded()` and descendant fields gate
  geometry; paint-only work reuses clean geometry; compositor-only work does
  not enter this module.
- General DOM mutation destroys layout while the old DOM is alive. The narrow
  retained-insert path is valid only after a one-to-one DOM-backed block match
  and must synchronously rebind every moved child pointer.
- Layout-to-layout dependencies use the common layout allocator. Dependencies
  published by computed-style fields use that StyleMap's allocator. Pass the
  same allocator when destroying the source field.
- Short-lived rich-button/embed records may copy values but must not subscribe
  their own ProtectedFields to persistent DOM/layout sources.
- Layout invalidation dirties paint. Paint invalidation follows layout ancestry
  without republishing geometry. Compositor-only opacity/translation dirties
  neither.

## Paint and command ownership

- Document, block, line, and text objects own stable paint-cache list fields.
  Dirty leaves replace their buffers; ancestors rebuild shallow wrappers and
  order around non-owning `.cached_subtree` edges.
- `.cached_subtree` may exist only in a synchronous Frame/layout list. Cleanup
  does not own it. Composition and raster snapshots materialize it before a
  Browser lock or thread boundary. Temporary rich-button trees use
  `retained_commands.appendClone` because their layout owners retire before
  the outer line is committed.
- `.blend` and `.transform` own children; `.blend` owns its copied mode string.
  Image/glyph leaves borrow pixels, canvas leaves own immutable pixels, and
  provenance borrows the current DOM/layout generation.
- Effect wrapping is transactional: convert a temporary command list to an
  owned slice before calling `paint_effects.wrapOwned`. When transferring the
  returned owning items into another list, reserve its capacity first and free
  only the now-empty top-level container after the transfer.
- A direct child context that contains a float or positioned child may flatten
  one retained cache into the bounded phase sequence: negative positioned,
  static block backgrounds/borders, floats, inline/content, positioned
  auto/zero, then positive positioned. Split only ordinary effect-free static
  blocks. Positioned, clipped, blended, transformed, scrolling, table, and
  inline-wrapper subtrees remain atomic; never crack their effect wrapper to
  improve ordering.
- Retire Frame and Browser command generations before replacing decoded image,
  font, canvas, DOM, layout, or layer resources they borrow.
- A raster snapshot and every worker plane is independently owned through the
  SMP allocator. Plane pixels never return to the DOM/Tab worker.

## Geometry and interaction

- Hit testing descends in parent-local coordinates, inverts live transforms,
  applies scroll/clips locally, and visits reverse paint order. Do not build an
  absolute rectangle for every descendant.
- A `layout_hit.ReverseOrder` borrows a committed child permutation only for
  the current traversal. If that permutation is absent or stale, it falls back
  to reverse DOM order rather than retaining a layout-owned slice.
- Immediate children use stable phase order; signed z-index then DOM index
  orders only negative and positive positioned phases. A split static block
  contributes background early and content in the later inline phase. Exact
  command hit testing is authoritative for that split; structural fallback
  uses a separately committed content-aware reverse permutation.
- Rounded paint groups carry hit-clip metadata so descendant text/control
  commands cannot restore a square target.
- Focus geometry unions nested inline fragments once per visual line; a
  focusable block replaces only its own fragments with one block box.
- Layout coordinates contain authored CSS zoom. Raster applies accessibility
  zoom once. Preserve that distinction for geometry, glyphs, replaced
  elements, effects, focus, and hit testing.
- FontManager sizes are pixel em sizes, including emoji. Do not insert a
  CSS-pixel-to-point conversion before SDL_ttf's default 72-DPI font API.
- Replaced size resolution happens before authored zoom and keeps the element
  box separate from object-fit image geometry and fractional source crop.

## Compositing

- The page interest region is bounded to four native window heights. Scroll
  inside it is draw-only; crossing an edge or changing geometry invalidates it.
  Frame-viewport transforms and fixed background tiles instead use a single
  viewport region and re-raster on every root scroll, because their pixel
  phase cannot translate with a cached document strip.
- A compositor plane owns either a surface or an independent short cheap-command
  snapshot. Expensive/resources/effectful commands remain surface-backed.
- Reject static merging before the union exceeds one megapixel; an
  intrinsically larger single chunk remains valid.
- An active transform is an assume-overlap barrier for the complete raster
  generation.
- Fold opacity-only ancestry around one `DrawCompositedLayer` into its draw
  multiplier. Preserve isolation for masks, filters, blend operators, or
  multi-command group opacity.

## Verification

Run `zig build test-render`, then `zig build test-pipeline` for semantic
style/layout/display output. Run `zig build verify` before handoff and native
macOS `zig build test-screenshot` for pixel-sensitive changes. Add a focused
unit regression for ownership/cleanup and update the relevant
[manual fixture](../../../tests/manual/README.md) for interaction or visual
behavior.
