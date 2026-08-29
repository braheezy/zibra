# Architecture overview

This document describes Zibra's major owners and the boundaries between them.
Read the domain document linked from
[`architecture-and-lifetimes.md`](../architecture-and-lifetimes.md) before
changing a boundary; this overview is not a substitute for those contracts.

## Source map

| Area | Primary responsibility |
| --- | --- |
| `src/main.zig` | CLI parsing, isolated inspection modes, interactive startup, and standalone screenshot startup |
| `src/browser/app.zig` | Process-wide SDL event routing, native-window registry, shared session, and shared measurement |
| `src/browser/root.zig` | One native window, tabs and chrome, render commits, raster coordination, and native presentation |
| `src/browser/resource_loader.zig` | Session-backed navigation/subresource dispatch and joined resource batches |
| `src/browser/software_renderer.zig` | Browser-free z2d command drawing, effects, image sampling, and layer rasterization |
| `src/browser/presentation_worker.zig` | Per-window raster runner, worker caches/surfaces, result transfer, and teardown |
| `src/browser/tab.zig` | Serialized page work, render orchestration, Frame-tree coordination, focus, and accessibility |
| `src/browser/frame.zig` | Per-document DOM/style/layout/display generations, child Frames, hit testing, and default actions |
| `src/browser/history.zig` | Owning pointer-free joint root/iframe session history |
| `src/browser/tab_animation.zig` | Animation advancement and render-phase classification |
| `src/browser/render/` | Layout, fonts, display commands, software effects, raster snapshots, and compositor planes |
| `src/document/` | DOM, HTML and CSS parsing, selectors, computed style, canvas backing, and pure CSS helpers |
| `src/script/` | Kiesel host integration, JavaScript realms, DOM handles, events, timers, and XHR |
| `src/network/` | Owning URLs, requests, redirects, response decoding, cookies, and caching |
| `src/runtime/` | Named task runners, joined thread batches, synchronization, and measurement |
| `src/core/` | Low-level primitives, including compile-time `ProtectedField` invalidation values |

Focused modules own algorithms or data with a lifecycle of their own. Avoid
splitting an oversized coordinator into facade files whose functions still
take the complete coordinator and create import cycles.

## Runtime topology

```text
process main / BrowserApp thread
  owns SDL event polling and text input
  owns shared BrowserSession and MeasureTime
  owns heap-stable Browser pointers, one per native window
    Browser
      owns native window/chrome/final-presentation state and tabs
      embeds one resource Loader and retained display Compositor
      embeds one software Renderer and presentation Worker
        presentation Worker owns one raster-and-draw TaskRunner
      Tab
        owns Frame tree, DOM generations, and one serialized TaskRunner
        owns one accessibility TaskRunner

BrowserSession
  owns one networking TaskRunner
    linked-resource tasks may start a synchronous joined transport batch

Detached timer/animation/XHR helpers
  own or borrow accounted payloads
  enqueue generation-stamped work back to the Tab runner
```

This is not a strict actor model. The UI thread and tab worker still reach
parts of the page layout and accessibility graph without one comprehensive
owner-thread assertion. Treat that as an open contract, not as permission to
add another cross-thread raw pointer.

## Principal owners

### BrowserApp

Interactive `BrowserApp` owns process SDL initialization, text input, the only
SDL event-polling loop, a process SDL_ttf guard, the shared `BrowserSession`,
the shared heap-stable `MeasureTime`, and the registry of heap-stable Browser
pointers. Remove a Browser from the registry before quiescing it so stale
window-addressed events cannot reach retired storage.

### Browser

One `Browser` owns a native window's renderer, texture and z2d presentation
surfaces; its tabs; its private HTML chrome and chrome layout/font state; and
the window's page layout/font engine. Concrete embedded owners hold committed
display/compositor state, session-backed loading, the pure software command
interpreter, and raster runner/cache/result state. Browser still coordinates
their inputs and exclusively performs final SDL upload/presentation.
`Browser.initAppWindow` borrows App services. Standalone `Browser.init` owns the
corresponding SDL/session/measurement services for the windowless screenshot
path. Keep those destruction paths explicit.

The Browser is heap-stable because z2d context state points into it. Browser
registry growth moves only pointers, never Browser values.

### BrowserSession

`BrowserSession` is independent of native windows. It owns the HTTP client,
cookie jar, response cache, networking runner, and canonical visited/bookmark
strings. Its network-data mutex protects cookie/cache storage; its metadata
mutex protects URL sets. Neither mutex may be treated as a lock for Browser,
Tab, DOM, or layout state.

### Tab and Frame

A Tab owns its root Frame tree, per-origin JavaScript hosts, a standalone
pointer-free `history.State`, frame and document generations, serialized task
runner, accessibility runner and tree, and animation/helper accounting. It
borrows its Browser and MeasureTime. `tab_animation.zig` advances Element-owned
tracks through a narrow synchronous sink; Tab still owns animation scheduling
and render-phase orchestration.

A Frame's implementation lives in `frame.zig` behind a comptime boundary that
avoids importing the Tab coordinator back through a cycle. It owns its decoded
HTML, root DOM value, child Frames, current URL,
stylesheet source/rule/keyframe generation, protected document-layout pointer,
frame-side display list, and copied hit/focus/image/fragment indexes. Raw
parent, frame-element, focus, hover, layout, and callback pointers borrow only
the current document generation.

### Document, layout, and render generations

DOM nodes borrow their parsed source for most strings. Layout borrows DOM,
computed style, decoded images, and font glyphs. A frame display list can also
borrow retained layout paint caches. Browser-side command state borrows its
producing document resources until a raster snapshot copies every leaf needed
by the worker. Destruction therefore proceeds from display consumers back to
source owners; see
[`document-and-rendering.md`](document-and-rendering.md).

## Allocator and native-resource domains

- Production application objects normally use the process arena. Explicit
  `free`, `destroy`, and `deinit` calls still define logical ownership; arena
  behavior can hide leaks and use-after-free bugs.
- Kiesel's host object is allocated from scanned, uncollectable storage so its
  embedded agent remains a GC root. The Zig process arena is not a Kiesel root.
- Raster jobs, copied command leaves, worker caches, and transferred surfaces
  use `std.heap.smp_allocator`. Preserve the allocator when ownership of a
  completed surface moves to the UI thread.
- Each initialized canvas owns a heap-stable z2d Surface/Context pair because
  the context borrows the embedded surface address.
- Each FontManager owns SDL_ttf handles and allocator-owned RGBA glyph pixels.
  Display commands borrow those pixels until a raster snapshot copies them.
- Renderer-bound SDL objects stay on the UI thread. Software raster workers do
  not call SDL.

Use `std.testing.allocator` or another reclaiming allocator for
ownership-sensitive tests; success under the production arena is insufficient
evidence of a correct lifetime.

## Inspection pipeline

The CLI modes intentionally stop at different boundaries:

| Mode | Last phase entered |
| --- | --- |
| `--dump-dom` | fetch, decode, and HTML parse |
| `--dump-style` | stylesheet collection and computed style |
| `--dump-layout` | font measurement and geometry, without interactive state |
| `--dump-display-list` | paint-command generation, without compositing or raster |
| `--screenshot` | windowless software composition and raster to PNG |

Do not construct a Browser merely to reuse a helper in a narrower inspection
mode. These boundaries are diagnostic contracts and should remain independently
testable.
