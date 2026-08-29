# Browser subsystem guide

This directory owns the interactive app, each native-window Browser, tabs and
frames, chrome, navigation/resource orchestration, and presentation workers.

Read the architecture pages for the boundary being changed:

- [overview](../../docs/architecture/overview.md) for process/window/Tab/Frame
  ownership;
- [threads and shutdown](../../docs/architecture/threads-and-shutdown.md) for
  task runners, SDL affinity, helpers, locks, and teardown;
- [navigation and network](../../docs/architecture/navigation-and-network.md)
  for document generations, history, loading, and session state;
- [document and rendering](../../docs/architecture/document-and-rendering.md)
  for phase guards, layout/display lifetimes, and DOM mutation;
- [JavaScript and accessibility](../../docs/architecture/javascript-and-accessibility.md)
  for host callbacks, focus, timers, and speech.

The nested [`render/AGENTS.md`](render/AGENTS.md) adds rendering-specific rules.

## Local map

| Module | Owner or boundary |
| --- | --- |
| `app.zig` | Sole interactive SDL poller, shared session/measurement, heap-stable Browser registry |
| `root.zig` | One native window, tabs/chrome, fetch/render orchestration, raster result acceptance, native presentation |
| `tab.zig` | Frame tree, document generations, serialized page work, history, focus/accessibility state |
| `session_state.zig` | Window-independent HTTP/cookie/cache and visited/bookmark state plus networking runner |
| `tab_tasks.zig` | Owned payloads transferred from UI/Browser to a Tab runner |
| `js_context.zig` | Stable synchronous generation-stamped host-callback identity embedded in a Frame |
| `script_tasks.zig` | Detached/queued timer, animation, XHR, cookie, and message adapters |
| `chrome.zig` | UI-thread-only internal HTML chrome, its DOM/layout/font/display generation |
| `navigation.zig` | Generated warning pages and transport-security classification |
| `image_loader.zig` | Eager/lazy HTML-image selection, fetch/decode ownership, fallback state |
| `frame_timing.zig` | Frame estimator and absolute animation deadlines |
| `window_geometry.zig` | Pure replacement geometry for native resize |
| `scroll.zig` | Scroll ranges, interest-region geometry, and viewport scroll animation |

`root.zig` remains an oversized coordinator. Do not add an independent
algorithm or standalone data owner there by default. Natural extraction seams
include resource coordination and the per-window presentation worker, but an
extraction must have explicit inputs, ownership, and shutdown without a
circular facade.

## Thread and ownership rules

- `BrowserApp` alone polls SDL and owns process text input. It removes a Browser
  from the registry before quiescing/destroying it.
- A Browser is heap-stable. Interactive construction borrows App session,
  measurement, text-input, and SDL services; standalone screenshot construction
  owns them. Preserve those distinct teardown paths.
- SDL window/renderer/texture/title/dialog/presentation calls stay on the UI
  thread. Raster workers use self-contained SMP-allocated software snapshots.
- Every Tab task or helper that can cross navigation carries a copied document
  identity. Never queue a borrowed `*Frame`, `*Node`, or `JsRenderContext`.
- Tab workers do not mutate Browser tab/chrome collections. Cross-thread new
  tabs transfer an owning `Url`; ownership moves only after successful queueing.
- Stop the raster runner before tabs/fonts/surfaces/native handles. Stop a Tab's
  serialized producer before its accessibility runner. Stop the session
  networking runner only after every Browser/helper borrow has ended.
- Keep Browser/session lock scopes narrow and follow the ordering in the thread
  document. Do not hold Browser locks during network I/O, JavaScript, software
  raster, or native confirmation dialogs.

## Frame and render-phase rules

- `Frame.document` is a protected style-phase guard. A dirty value cannot be
  read by layout or hit testing. Successful style/resource processing
  republishes it before `DocumentLayout.layoutNeeded()` gates geometry.
- Do not reintroduce tab-wide `needs_style` or `needs_layout`. Paint remains
  independent; compositor-only opacity/translation should avoid all three
  full phases.
- Retire a Frame display list and DOM-keyed bounds before rebuilding/destroying
  layout or DOM. It may contain provenance and non-owning retained-cache edges.
  Composition must materialize edges and clear provenance before commit.
- Structural DOM mutation uses the synchronous retirement/completion boundary.
  Network loading of new resources happens after the host call returns.
- Each Frame owns its URL, decoded HTML, stylesheet source/rule/keyframe
  generation, layout pointer, display list, and child Frames. Raw parent,
  frame-element, focus/hover, and layout pointers borrow that generation.
- Child Frame media width divides authored-zoom-scaled geometry by its inherited
  authored factor. Parent viewport changes dirty child layout before the
  follow-up media/style pass.

## Input and accessibility rules

- Page input crosses to the serialized Tab runner as scalar values or stable
  IDs. Do not retain a layout/DOM hit result on the UI thread.
- Focus transitions use the tab-wide blur/focus handoff. Sequential focus spans
  the whole Frame tree. `:focus-visible` and the native ring consume the same
  modality snapshot.
- Hover is deferred until a clean layout exists, then style-invalidates the
  changed path for a second render.
- Accessibility speech tasks own flattened bytes and no page pointer. Tree
  rebuilds keep old strings alive through diff/remapping.
- Chrome owns a private UI-only DOM/layout/font/display generation. Never share
  the page layout engine with it. Preserve the 66px outer chrome boundary.

## Verification

Run `zig build test-browser` while iterating. Use `zig build test-render` for
layout/paint ownership, `zig build test-network` for loading/session changes,
and `zig build test-script` for callback or DOM integration. Before handoff run
`zig build check`; run `zig build test-pipeline` for document rendering and
native macOS `zig build test-screenshot` for final pixels. Add/update a primary
manual fixture and its [catalog entry](../../tests/manual/README.md) when
interaction cannot be expressed deterministically in an automated test.
