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
  dependencies, local-coordinate hit testing, focus/image/iframe bounds, and
  retained paint caches. It borrows DOM, computed style, decoded images, and
  FontManager resources.
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
- `replaced_sizing.zig`, `focus_ring.zig`, and `forced_colors.zig` are pure
  focused helpers. Keep Browser orchestration out of them.

`layout.zig` is already beyond the repository's decomposition threshold. New
independent formatting, replaced-element, or paint algorithms should become a
cohesive module with a real owner/interface rather than another region in that
file. Do not split methods away from the object invariants they maintain or add
a facade cycle merely to reduce lines.

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
  Browser lock or thread boundary.
- `.blend` and `.transform` own children; `.blend` owns its copied mode string.
  Image/glyph leaves borrow pixels, canvas leaves own immutable pixels, and
  provenance borrows the current DOM/layout generation.
- Retire Frame and Browser command generations before replacing decoded image,
  font, canvas, DOM, layout, or layer resources they borrow.
- A raster snapshot and every worker plane is independently owned through the
  SMP allocator. Plane pixels never return to the DOM/Tab worker.

## Geometry and interaction

- Hit testing descends in parent-local coordinates, inverts live transforms,
  applies scroll/clips locally, and visits reverse paint order. Do not build an
  absolute rectangle for every descendant.
- Immediate children paint by stable `(effective z-index, DOM index)` order;
  only non-static positioned blocks receive nonzero z-index. Hit testing uses
  the exact reverse order.
- Rounded paint groups carry hit-clip metadata so descendant text/control
  commands cannot restore a square target.
- Focus geometry unions nested inline fragments once per visual line; a
  focusable block replaces only its own fragments with one block box.
- Layout coordinates contain authored CSS zoom. Raster applies accessibility
  zoom once. Preserve that distinction for geometry, glyphs, replaced
  elements, effects, focus, and hit testing.
- Replaced size resolution happens before authored zoom and keeps the element
  box separate from object-fit image geometry and fractional source crop.

## Compositing

- The page interest region is bounded to four native window heights. Scroll
  inside it is draw-only; crossing an edge or changing geometry invalidates it.
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
style/layout/display output. Run `zig build check` before handoff and native
macOS `zig build test-screenshot` for pixel-sensitive changes. Add a focused
unit regression for ownership/cleanup and update the relevant
[manual fixture](../../../tests/manual/README.md) for interaction or visual
behavior.
