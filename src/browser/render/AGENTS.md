# Browser rendering guide

This directory owns layout, font resources, display-command structure,
software effects, and worker-transfer snapshots. Read
[`../../../docs/architecture-and-lifetimes.md`](../../../docs/architecture-and-lifetimes.md)
before changing ownership or thread boundaries.

- `layout.zig` builds layout trees and emits provenance-bearing display items.
  Layout and frame-side command lists synchronously borrow DOM and image state.
  Point queries walk document/block/line/text objects in reverse order and
  carry parent-local coordinates: each object subtracts its own offset and
  live translation, while scroll containers add their live scroll before
  descending. Inline-mode blocks retain an exact painted-command leaf fallback
  until they gain persistent line/text children. Do not reconstruct an
  absolute rectangle for every descendant.
  Focus-bound collection uses `document/focus.zig`'s programmatic policy so
  script-focusable negative-tabindex targets receive geometry even though
  sequential keyboard traversal skips them.
  Immediate layout children paint through a retained stable index permutation
  keyed by effective z-index and DOM index. Only positioned blocks receive a
  nonzero signed z-index; lines and static/invalid blocks stay at zero. Recurse
  with the same rule for nested stacking, and use its reverse order for layout
  hit queries so visual and interaction order cannot diverge. Refresh the
  permutation at paint and retain it with that display generation.
  Active width/height transitions override their computed pixel endpoints here;
  every frame relayouts descendants so line wrapping follows animated width.
  Document/block/line `in_layout` guards suppress only reentrant owner-wide
  invalidation caused by child metrics during that same serialized traversal.
- `font.zig` owns SDL_ttf handles and cached RGBA glyph pixels. Display items
  borrow those pixels until a raster snapshot copies them.
- `display_list.zig` owns display-command types, recursive cleanup, painted hit
  testing, and composited-layer data. A `DrawCompositedLayer` carries a
  draw-local opacity multiplier separately from the layer's live compositor
  opacity; opacity-only paint ancestors multiply that scalar so the cached
  surface is sampled once during its final draw. Keep this module independent
  of `Browser`, SDL, and native-window lifecycle.
- `layout.zig` resolves every painted inline fragment to its nearest focusable
  DOM ancestor and unions those fragments once per visual line. Nested inline
  descendants therefore share their ancestor's wrapped focus geometry. After
  child layout, a block-displayed focusable element replaces only its own line
  fragments with one block box; independently focusable descendants remain.
- `focus_ring.zig` generates pointer-free focus-indicator commands. Each
  published focus rectangle is padded and painted as a 4px white outline
  followed by a 2px black outline; reserve both commands before appending
  either so OOM cannot publish a half-ring. Accessibility highlighting remains
  a separate requested-color outline.
- `forced_colors.zig` owns the fixed semantic high-contrast palette. Layout
  assigns paint roles before author colors are replaced, so backgrounds,
  ordinary text, link states, controls, borders, and cursors cannot collapse
  into an author-selected low-contrast pair. Transparent paint remains
  transparent; image pixels and color emoji are content and are not recolored.
- `effects.zig` contains pixel-only software effects. Keep its APIs explicit
  about premultiplication, edge sampling, and temporary allocation.
- `raster_snapshot.zig` is the thread-transfer boundary. Snapshots must deep
  copy every resource-backed leaf, clear synchronous provenance, and reject
  browser-owned layer pointers. Numeric compositor IDs may cross this boundary;
  raw DOM/layout pointers may not.
- `compositor_cache.zig` owns ordered raster-worker planes and applies only
  scalar opacity/translation updates before draw. A live plane owns exactly
  one backing: an RGBA surface, or an independent `RasterSnapshot` containing
  at most three cheap rect/rounded-rect/line/outline commands. Direct planes do
  no raster work and replay during draw; text, images, filters, blend modes,
  and unsafe multi-command opacity groups retain surfaces. Static strata may
  merge
  backward across stable dynamic planes only when their tight painted bounds
  do not overlap. Static surfaces are cropped to the interest region and their
  painted bounds; stop a merge before its union exceeds the fixed one-megapixel
  allocation budget, while allowing an intrinsically larger individual paint
  chunk. Merging may keep a direct plane direct or transactionally promote it
  to a surface when it crosses the threshold. An active transform is an
  assume-overlap barrier: later paint must
  remain after it even when the current rectangles are disjoint, because a
  future compositor update can create overlap. Plane pixels never return to
  the DOM/tab thread, and fallback decisions remain Browser orchestration.

Prefer adding a focused rendering module when a feature introduces a distinct
data owner or pipeline phase. Do not move Browser orchestration into this
directory merely to reduce a line count.

Run `zig build`, `zig build test`, the dump-pipeline checks, and macOS
`zig build test-screenshot` after rendering behavior or ownership changes.
