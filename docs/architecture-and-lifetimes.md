# Zibra Architecture and Lifetime Contracts

## Status and scope

This document describes the architecture and lifetime behavior visible in the
current source tree. It is an audit of the implementation, not a claim that
every current behavior is safe or intentional.

Some contracts are enforced today, some have recently been repaired, and some
remain unresolved. Those categories are kept separate below. In particular, a
generation check, mutex, arena allocator, idle poll, or process exit must not be
treated as proof that a borrowed pointer is still alive.

The terms used here are:

- **owns**: responsible for releasing an allocation or native resource;
- **borrows**: may use a value only while another owner remains alive and
  stable;
- **moves**: transfers responsibility for releasing a value;
- **snapshot**: data handed from the tab worker to the browser/render side that
  must remain valid until the render side retires it;
- **confirmed**: a property or ordering directly visible in the source;
- **hypothesis**: a possible failure mode whose required interleaving or
  platform behavior has not yet been demonstrated by a focused test.

Source references link to files and name the relevant type or function instead
of using fragile line anchors.

## Source layout

The source tree is organized by responsibility:

| Area | Responsibility |
| --- | --- |
| [`src/main.zig`](../src/main.zig) | Executable entry point, CLI parsing, process arena, isolated DOM/style/layout/display-list dumps, interactive `BrowserApp` construction, and standalone screenshot mode. |
| [`src/browser/app.zig`](../src/browser/app.zig) | Process-wide interactive SDL event routing, heap-stable native-window registry, shared session/measurement ownership, generation broadcast, and addressed window shutdown. |
| [`src/browser/root.zig`](../src/browser/root.zig) | Per-window `Browser`, navigation and fetch coordination, render commit, composition, raster, draw, and standalone headless construction; it re-exports compatibility types while delegating independent algorithms and task payloads to focused modules. |
| [`src/browser/tab.zig`](../src/browser/tab.zig) | `Tab` and `Frame` ownership, task serialization, history, frame lookup, accessibility, focus, and per-document state. |
| [`src/browser/accessibility_speech.zig`](../src/browser/accessibility_speech.zig) | Per-tab owned speech snapshots, the named accessibility runner, backend dispatch, cancellation, and join boundary. |
| [`src/browser/tab_tasks.zig`](../src/browser/tab_tasks.zig) | Owned navigation, script, and tagged UI-action payloads transferred to a serialized Tab runner; instantiated with the Browser type without importing `root.zig`. |
| [`src/browser/js_context.zig`](../src/browser/js_context.zig) | Stable generation-stamped synchronous host-callback identity embedded in each JavaScript-capable Frame. |
| [`src/browser/script_tasks.zig`](../src/browser/script_tasks.zig) | Detached timer, animation, asynchronous XHR, cookie, and postMessage callback adapters and queued payload cleanup, instantiated without importing `root.zig`. |
| [`src/browser/chrome.zig`](../src/browser/chrome.zig) | Browser-owned internal HTML chrome, its dedicated layout/font state, semantic actions, address editing, and retained display data. |
| [`src/browser/navigation.zig`](../src/browser/navigation.zig) | Browser-generated navigation documents, certificate-warning HTML, and committed transport-security classification. |
| [`src/browser/image_loader.zig`](../src/browser/image_loader.zig) | Eager/lazy HTML-image selection, URL resolution, fetch/decode ownership, batch deduplication, and broken-image fallback. |
| [`src/browser/frame_timing.zig`](../src/browser/frame_timing.zig) | Smoothed two-stage frame-work estimates, cadence buckets, and absolute animation deadlines. |
| [`src/browser/window_geometry.zig`](../src/browser/window_geometry.zig) | Pure native-window resize and bounded tab-surface geometry derivation. |
| [`src/browser/session_state.zig`](../src/browser/session_state.zig) | Window-independent networking task runner, HTTP client/cookies/cache, visited/bookmarked URL state, generated bookmark HTML, and separate network-data/metadata synchronization. |
| [`src/browser/render/layout.zig`](../src/browser/render/layout.zig) | Layout tree, invalidation dependencies, hit-test collection, paint, and replaced-element layout. |
| [`src/browser/render/replaced_sizing.zig`](../src/browser/render/replaced_sizing.zig) | Pure image/iframe width, height, intrinsic-size, and CSS aspect-ratio resolution. |
| [`src/browser/render/font.zig`](../src/browser/render/font.zig) | Font discovery, SDL_ttf handles, Unicode fallback selection, and owned RGBA glyph bitmaps. |
| [`src/browser/render/display_list.zig`](../src/browser/render/display_list.zig) | Display-command and composited-layer data, recursive ownership cleanup, provenance, and painted hit testing without Browser or SDL dependencies. |
| [`src/browser/render/focus_ring.zig`](../src/browser/render/focus_ring.zig) | Pointer-free high-contrast focus-ring and accessibility-outline command generation. |
| [`src/browser/render/forced_colors.zig`](../src/browser/render/forced_colors.zig) | Semantic four-color accessibility palette and author-color replacement. |
| [`src/browser/render/effects.zig`](../src/browser/render/effects.zig) | Pixel-level software effects such as premultiplied-RGBA Gaussian blur. |
| [`src/browser/render/raster_snapshot.zig`](../src/browser/render/raster_snapshot.zig) | Deep-owned, provenance-free display generations transferred to the raster worker. |
| [`src/browser/render/compositor_cache.zig`](../src/browser/render/compositor_cache.zig) | Raster-worker-owned ordered planes, surface-or-short-command backing, and pointer-free opacity/translation updates used by draw-only animation and scrolling. |
| [`src/document/parser.zig`](../src/document/parser.zig) | HTML parser, DOM representation, style maps, image/canvas owners, and DOM tree utilities. |
| [`src/document/background_image.zig`](../src/document/background_image.zig) | Pure CSS background URL/size parsing and used-size resolution. |
| [`src/document/object_fit.zig`](../src/document/object_fit.zig) | Pure parsing and centered destination/source-crop geometry for replaced images. |
| [`src/document/canvas.zig`](../src/document/canvas.zig) | Heap-stable z2d canvas backing stores, 2D command dispatch, state, resizing, and straight-alpha snapshots. |
| [`src/document/focus.zig`](../src/document/focus.zig) | Shared intrinsic programmatic and sequential HTML focusability rules. |
| [`src/document/inspection.zig`](../src/document/inspection.zig) | Browser-free fetch/decode/parse/style pipeline for document inspection commands. |
| [`src/document/css_parser.zig`](../src/document/css_parser.zig) | CSS parsing and `CSSRule` ownership. |
| [`src/document/color.zig`](../src/document/color.zig) | Shared parsing for paintable named and hexadecimal RGBA CSS colors. |
| [`src/document/easing.zig`](../src/document/easing.zig) | Owned CSS timing functions and cubic-Bezier evaluation. |
| [`src/document/length.zig`](../src/document/length.zig) | Shared parsing, context-based CSS-pixel resolution, layout conversion, and serialization for supported non-negative `px`, `em`, and percentage lengths. |
| [`src/document/transform.zig`](../src/document/transform.zig) | Shared parsing and interpolation-ready representation for supported CSS translations. |
| [`src/document/selector.zig`](../src/document/selector.zig) | Selector representation and matching. |
| [`src/network/url.zig`](../src/network/url.zig) | Owning `Url`, URL resolution, schemes, HTTP requests, redirects, cookies, response bodies, and cache integration. |
| [`src/network/cache.zig`](../src/network/cache.zig) | Browser-session HTTP response entries, expiry, and strict `Cache-Control` policy parsing. |
| [`src/script/js.zig`](../src/script/js.zig) | Kiesel host integration, realms/windows, DOM handles, JavaScript evaluation, events, timers, XHR, and host callbacks. |
| [`src/runtime/task.zig`](../src/runtime/task.zig) | Named serialized task workers for tabs/networking and opaque task-context cleanup. |
| [`src/runtime/thread_batch.zig`](../src/runtime/thread_batch.zig) | Synchronous start-all/join-all thread batches with caller-owned job/result slots. |
| [`src/runtime/sync.zig`](../src/runtime/sync.zig) | Runtime synchronization wrappers. |
| [`src/runtime/measure_time.zig`](../src/runtime/measure_time.zig) | Cross-thread measurement and profiling state. |
| [`src/core/protected_field.zig`](../src/core/protected_field.zig) | Reactive dirty/invalidation fields used by style and layout. |
| [`src/tests/`](../src/tests) and [`src/test_root.zig`](../src/test_root.zig) | Zig tests. |

## Runtime topology

The runtime currently separates its owner threads and accounted helpers as
follows:

```text
process main thread
  interactive BrowserApp
    sole SDL event poller and text-input owner
    shared BrowserSession (HTTP/cookies/cache/visited/bookmarks)
      one Networking thread and queued browser fetches
    shared MeasureTime
    native window registry
      Browser A                 Browser B ...
        tabs/chrome/render        tabs/chrome/render
        Raster/draw worker        Raster/draw worker
        page + chrome Layouts     page + chrome Layouts
        two FontManagers          two FontManagers
        SDL window/renderer       SDL window/renderer
  or standalone screenshot Browser
    windowless software loop and owned session/measurement
          |
          | each Browser schedules Task values
          v
  one TaskRunner worker per Tab
    navigation, parsing, DOM, style, layout, paint, JavaScript host work
    |
    |-- owned role/name/value snapshot; no page pointer crosses
    |     `--> one Accessibility thread per Tab
    |            serialized speech backend calls
    |
    | synchronous fetch bridge submits borrowed request inputs
    v
    shared BrowserSession Networking thread
      navigation, image, iframe, XHR, script/style batch dispatch
          |
          | linked-resource batches start/join transport workers
          | (results remain in source-order slots)
          v
    HTTP/file/data transport and response ownership

  Tab work also spawns accounted non-transport helper threads
          v
    setTimeout/setInterval helper thread(s), animation timer thread,
    async XHR completion thread(s)
          |
          `---- enqueue completion Task values back onto the Tab worker
```

The entry point uses `init.arena.allocator()`. Interactive mode constructs one
heap-stable `BrowserApp`, which allocates one heap-stable `Browser` per native
window. Registry growth moves only borrowed Browser pointers. Browser heap
stability is required because z2d `Context` stores a pointer to
`Browser.root_surface`. Screenshot mode bypasses the App and constructs one
standalone, windowless Browser so the headless compatibility path stays
isolated. Each `Tab` owns one `TaskRunner`. `Tab.start` must run only after the
Tab reaches its final address because the worker retains a pointer to the
tab-owned runner; see `zibra` and `Tab.start` in
[`src/main.zig`](../src/main.zig) and [`src/browser/tab.zig`](../src/browser/tab.zig).

This is not currently a strict actor model. Main-thread input handlers read or
mutate some `Tab`, `Frame`, accessibility, scroll, `Layout`, and `FontManager`
state while the tab worker can also use those objects. The code has local locks,
but no lock or owner-thread rule covers the complete mutable graph.

## Allocator and native-resource domains

| Domain | Current owner and release behavior | Important contract |
| --- | --- | --- |
| Process arena | Normal application allocations use the process arena in [`src/main.zig`](../src/main.zig). Individual `free` and `destroy` calls still express logical ownership even when the arena does not promptly reclaim most allocations. | Arena behavior can hide leaks and delay visible corruption. Ownership-sensitive code should also be exercised with `std.testing.allocator` or a GPA. |
| Kiesel host object | With libgc enabled, `Js.init` allocates `Js` from BDWGC's scanned, uncollectable allocator so its embedded `Agent` remains a collector root. `Js.deinit` releases the agent/platform and destroys the host object through its storage allocator; see [`src/script/js.zig`](../src/script/js.zig). | Any Kiesel pointer reachable only from unscanned Zig memory must be rooted deliberately. The process arena is not a GC root. |
| Zibra collections | `Browser`, `Tab`, `Frame`, DOM, layout, rules, tasks, and snapshots generally retain the caller allocator and provide explicit teardown paths. | The explicit lifetime remains authoritative even when production allocation behavior masks a bad free order. |
| Raster worker | Raster task queues, snapshots, copied leaf pixels, z2d temporaries/caches, and completed surfaces use `std.heap.smp_allocator`; `root_surface_allocator` follows a transferred result into UI ownership. | The process arena is not used concurrently by the raster worker, and every transferred surface must be released through the allocator that created it. |
| SDL and SDL_ttf | BrowserApp owns interactive SDL/text input, each Browser owns its native window/renderer/texture, and each `FontManager.deinit` frees cached RGBA glyph bitmaps, closes fonts, and releases its paired SDL_ttf reference. The App holds an extra refcounted SDL_ttf guard until all windows close. | Native handles require deterministic release and an explicit thread-affinity rule. |
| z2d and zigimg | `Browser` owns long-lived presentation surfaces/contexts. Each initialized canvas element owns a heap-stable z2d Surface/Context pair; `ImageData` owns a `zigimg.Image` and, when present, its encoded byte buffer. | Image display items borrow decoded slices. Canvas paint instead copies and owns immutable pixels because scripts may mutate its live z2d surface after commit. |

## Ownership topology

### BrowserApp and Browser

Interactive `BrowserApp` in
[`src/browser/app.zig`](../src/browser/app.zig) owns:

- SDL video initialization, the process text-input lifecycle, and the only SDL
  event-polling loop;
- one extra SDL_ttf initialization reference held until every window's
  `FontManager` has closed its own paired reference;
- the heap-stable `BrowserSession` and `MeasureTime` shared by all windows;
- a registry of heap-stable Browser pointers keyed by native window ID.

The App removes a window from the registry before quiescing and destroying it,
so queued events for a stale ID cannot reach a retired Browser. An addressed
close destroys only that entry; closing the final entry exits the process
loop. SDL quit is ID-less and global. Escape also requests global quit, but it
first routes through a live source Browser so stale Escape events are ignored.
Raw finger events carry that same native window ID and remain routed to exactly
one Browser. SDL reports their positions in normalized coordinates, so the
receiving Browser converts them with its current native pixel dimensions and
tracks each `(touchId, fingerId)` contact independently. Release within a 10px
slop becomes the ordinary primary-click path; crossing the slop permanently
cancels that gesture, and focus loss clears every unfinished contact. This
tracker is UI-thread-only, owns no document pointers, and is destroyed with its
Browser. SDL mouse events carrying the reserved touch-mouse device ID and
finger events carrying the reserved mouse-touch device ID are ignored, so SDL's
bidirectional compatibility streams cannot activate one physical action twice.

Each `Browser` in [`src/browser/root.zig`](../src/browser/root.zig) owns:

- in interactive mode, one SDL window, renderer, and cached output texture;
  screenshot mode leaves all three absent;
- root, chrome, and optional tab z2d surfaces plus the root z2d context;
- one window-local page `Layout`, including its `FontManager`, plus Chrome's
  independent UI-thread-only `Layout`/`FontManager`;
- default user-agent CSS rules;
- all `Tab` allocations grouped in that native window;
- owning URLs queued by tab workers for browser-thread tab creation;
- the active browser-side display-list snapshot, composited layers, and tab draw
  list;
- one named serialized raster-and-draw runner, any queued self-contained
  command snapshot, and at most one completed software surface awaiting UI
  presentation;
- browser chrome, optimistic and committed active URL copies, and render flags.

`Browser.initAppWindow` explicitly borrows SDL/text-input ownership plus the
App's session and measurement pointers. Direct `Browser.init` instead owns all
four services for the standalone screenshot path (and retains legacy
standalone-interactive compatibility). The four `owns_*` flags make these two
destruction paths explicit. `MeasureTime` is heap-stable because every tab
worker across every window borrows it, and the App finishes it once only after
all Browsers have stopped.

Chrome is rebuilt as a small internal HTML document on the browser/UI thread.
Its DOM uses buttons for browser actions, an input for the address field, and
anchors for tab selection; its private stylesheet supplies the simplified
control geometry. Painted-command provenance is retained only with that chrome
generation, and click handling hit-tests the display list before walking the
internal DOM ancestry to a semantic action. The ownership order is display
list, document layout, DOM, source HTML, parsed rules, then the dedicated
layout/font engine. Rebuild and resize retire the previous generation in that
order. Chrome does not borrow the page layout engine because tab workers use
that engine concurrently. Its fixed 66px outer boundary remains part of the
document viewport contract even though the pixels within that boundary may
change independently of page screenshot goldens.

`BrowserSession` owns one heap-stable named `TaskRunner`, the shared
`std.http.Client`, cookie jar, decoded HTTP response cache, and canonical
serialized strings for visited and bookmarked URLs. Ordinary Browser fetches
submit a stack-backed request context to this networking runner and wait until
the task's cleanup callback posts completion. Request URL/referrer/payload
values are synchronous borrows across that wait; the response and optional
redirect URL then move back to the producer. Queue rejection still runs
cleanup, so shutdown cannot strand a waiter. The runner borrows shared
`MeasureTime` and must stop before either measurement or transport storage.
HTTP responses and cache entries carry X-Frame-Options as a scalar policy, so
cache hits cannot accidentally discard an embedding restriction and no header
slice gains another owner.

Zig opens client connections thread-safely. A dedicated network-data mutex
stabilizes cookie/cache lookup, copying, eviction, and mutation, but does not
cover a complete transport round trip; its metadata mutex protects both URL
sets independently of every `Browser.lock`.
The tutorial jar owns one host key, cookie value, retained parameter string,
derived SameSite/HttpOnly flags, and an optional absolute Unix expiration per
site. HTTP Set-Cookie and JavaScript assignments use the same transactional
parser. A new value replaces the old deadline; an already-expired assignment
deletes the existing public cookie, and HTTP/script reads lazily remove entries
whose deadlines have passed while the network mutex stabilizes their owning
keys and values. HttpOnly values remain eligible for browser-generated Cookie
request headers but are omitted from script reads and reject script
replacement. `document.cookie` callbacks copy their result while holding the
network mutex, release it, and then transfer a second copy to Kiesel's traced
heap because its ASCII string cache may retain input bytes.
Atomic generations publish mutations without exposing map storage. The App
polls those generations without holding either lock, then independently asks
every Browser for visited RAF work or bookmark chrome reraster work. Bookmark-page
generation first takes a lexicographically sorted snapshot whose list and
strings are independent owners, then HTML-escapes both link attributes and
labels. The HTML parser decodes references in attribute values into
`Element.owned_strings`, while source-backed DOM text stays escaped until the
layout text walker decodes it once. This preserves both injection safety and
exact bookmark-link/label round trips. Session teardown occurs only after all
tab workers and helpers have stopped. DOM anchors copy only a boolean
annotation, so they never borrow a URL-set key.

`Browser.fetchNavigationDocument` wraps document responses in a
`NavigationDocument` that explicitly owns allocated HTTP/file bodies and the
generated `about:bookmarks` HTML, while borrowed data/other-about bodies keep a
null owner. TLS certificate failures use the same contract for an owned,
peer-independent warning document and carry a certificate-error bit into the
installed frame. Root and child-frame loaders share this helper and release
the wrapper only after copying the body into the frame's decoded HTML owner.

`Tab.browser` is a borrowed back-pointer. Task and helper contexts also borrow
`Browser`; `Browser.deinit` therefore publishes shutdown, joins every tab
worker, waits for every accounted helper, and only then destroys that window's
state. BrowserApp retains shared session and measurement storage until all such
borrows from every window have ended.

### Tab

`Tab` in [`src/browser/tab.zig`](../src/browser/tab.zig) owns:

- indexed joint root/iframe history actions, their prior-subtree snapshots,
  and the current-entry index;
- a sentinel-terminated copy of the current root document's title;
- one root `Frame`, which recursively owns child frames;
- one Kiesel `Js` context per origin key;
- frame-ID maps plus tab-wide and per-document generation counters;
- the `TaskRunner` and accounting for detached helper threads;
- one named accessibility runner whose queued tasks own complete utterances;
- dynamic text allocations;
- the accessibility tree and its backing strings;
- per-tab dirty flags and composited updates.

`Tab` borrows its `Browser` and the heap-stable `MeasureTime` used by both of
its named runners. That measurement owner is BrowserApp in interactive mode
and the standalone Browser in screenshot mode.

### Frame

`Frame` in [`src/browser/tab.zig`](../src/browser/tab.zig) owns:

- child `Frame` allocations;
- the document's decoded HTML source;
- the root DOM `Node` value;
- document layout and the frame-side display list;
- owned CSS rules and keyframe containers plus their source buffers, including
  decoded linked sheets and copied `<style>` text retained in DOM order;
- hit-test collections, image visibility boxes, fragment target positions, and
  allowed-origin strings;
- its current URL whenever `current_url_owned` is true; every installed root
  and child document now uses this independent owner.

History entries own separate replay URL/body copies, so truncating a Forward
branch cannot invalidate the currently installed root URL. `parent`, `tab`,
`frame_element`, DOM focus and element-scroll focus pointers, hit-test node
pointers, `js_context`, and layout-related node pointers are borrowed.

Structural DOM mutation also marks the affected frame's resources dirty. On
the serialized tab worker, after the JavaScript host call has completed and
before the next style pass, the browser scans the final attached tree. Newly
attached classic scripts are copied into queued tasks and their DOM elements
record that evaluation has started; this identity moves with remove/re-attach,
while evaluated code remains in the document realm. Author stylesheets are
rebuilt as a staged rules-plus-keyframes-plus-source-buffer generation from the current DOM,
which both loads inserted `<style>`/`<link>` elements and retires rules from
detached links without leaving property slices pointing at freed CSS text.
Iframe browsing contexts use a split boundary: the synchronous mutation
completion pass validates Element-carried numeric window IDs, rebinds surviving
Frame pointers in final DOM order, and deinitializes contexts whose Elements
disappeared. Marker-free attached iframes are fetched only by the later resource
scan, after the host call has returned, through the same CSP, Referrer-Policy,
document-generation, and nested-frame loader used at navigation time. After
the final response URL is known, that loader applies X-Frame-Options before
publishing visits, history, or a child document: `DENY` rejects all embedding,
while `SAMEORIGIN` compares the response with every ancestor Frame URL and
fails closed if any ancestor identity is unavailable. Top-level navigation
does not consult this embedding-only policy.

CSS background images intentionally follow a later resource boundary. After
each initial or dynamic computed-style pass, `background_images.zig` walks the
final styled DOM and fetches only supported URLs actually selected on visible
elements. Each Element owns an attempted-source copy plus optional decoded
image data; identical computed URLs are stable across restyles, and one pass
deduplicates transport/decode work. Replacing that data first retires active
Browser render state under `Browser.lock` and the frame-side list, because both
may borrow its RGBA bytes. CSP and the document's Referrer-Policy are applied
before fetching; blocked and failed resources remain transparent. Forced-colors
treats decorative backgrounds as unused, avoiding a fetch for a newly loaded
document and releasing an earlier resource after its render borrowers retire.

HTML image discovery has a separate two-stage boundary. Missing, invalid, and
explicit `loading=eager` values load before initial layout; only an ASCII
case-insensitive `loading=lazy` defers the request. Layout publishes an
image-node box for every `<img>` and a one-pixel position anchor for an
unloaded intrinsic-only image, which still occupies zero line space. Before
pixels arrive, an explicitly authored width or height is retained independently
and participates in inline flow; an unspecified axis remains zero unless a
preferred aspect ratio derives it. The Frame copies those DOM-keyed coordinates
out of the shared Layout engine. After
layout and before every animation-frame dirty gate, the serialized Tab worker
selects lazy boxes within one frame viewport above or below the visible range
in CSS pixels (after accessibility zoom conversion) and synchronously bridges
their request through the session networking runner.
This pre-gate check is required because root scrolling can otherwise remain a
draw-only update. A decoded or stable broken image installs Element-owned
pixels, marks the complete `DocumentLayout` subtree, and schedules a follow-up
layout/paint so natural dimensions, line wrapping, page height, and iframe
composition are republished. Broken resources retain a terminal 16x16 fallback
and an `is_broken` tag so they are not retried; layout exposes those pixels and
their intrinsic size only when the current `alt` attribute is non-empty.
Missing or empty `alt` suppresses the icon while retaining any authored box.
DOM mutation retires the image-box map with the other raw-Node indexes before
child storage can move.

Root documents, child documents, and those mutation rescans discover every
external classic script and linked stylesheet into one fixed batch. Each slot
owns a resolved resource URL and independent referrer URL before work starts,
and retains its response until the tab worker consumes it. The complete batch
crosses the session networking queue as one synchronous task. On the networking
thread it starts every available transport worker before joining any thread;
native spawn failure falls back to a synchronous fetch for that slot. These
joined workers use the low-level synchronized transport directly, rather than
deadlocking by submitting back to their waiting coordinator. After the
complete join, the tab worker walks the DOM again, queueing scripts and parsing
stylesheets in source order. Thus network completion cannot reorder
classic-script execution or the CSS cascade, and navigation/shutdown cannot
retire the Browser, Frame, or URLs while a batch worker still borrows them.

Each tab records the visited generation represented by its display list. A new
session visit requests an animation frame; render compares generations before
its early dirty check, re-annotates every current frame, and forces paint when
stale. A middle-click records the target before transferring its owning URL to
the pending-tab queue, so the still-visible source document can repaint at
once; stale background documents refresh when activated.

History is mutated only by the serialized tab worker. Each successful root,
iframe, or same-document fragment navigation appends one joint-history action.
The entry owns the resulting request, a child-index path from the root Frame,
whether the action replaced a document, and a recursive URL/request snapshot
of the target subtree immediately before the action. Preparing that entry
clones all URLs, POST bodies, paths, and subtree containers before any current
document is retired. Frame paths, rather than `*Frame` values, remain valid
across a replay that creates new Frame allocations.

Ordinary navigation removes and releases actions after the current index
before appending. Back applies the current action's owned prior state; Forward
applies the next action's resulting request. Thus sibling iframe actions are
undone independently and a replaced parent iframe can recreate the precise
nested-frame state it destroyed. Root and iframe URLs installed during replay
remain Frame-owned and independent of history. The index advances only after
the full target/subtree operation succeeds. Chrome does not read the history
collection concurrently: it reads acquire/release atomic availability flags
and schedules a traversal task, which revalidates the requested adjacent move
and generation on the worker.

`Frame.deinit` destroys display/layout state before DOM and destroys DOM before
the decoded HTML source. That order is required because layout borrows DOM and
DOM strings borrow the HTML source. The frame display list is also the
authoritative synchronous click index: its optional provenance points at the
layout object that generated an item and at the originating DOM node. Those
pointers borrow exactly the current layout/DOM generation, so the list is
retired before `DocumentLayout.layout` can rebuild descendants as well as
before navigation or frame teardown destroys either tree.

Fragment target entries borrow DOM element pointers and store their top edge in
document-space CSS pixels. Layout collects block targets directly and inline
targets from positioned line content, including an insertion point for empty
inline targets. A frame copies that ephemeral layout-engine collection with its
other hit-test data, then releases it before either layout or DOM teardown.

Layout keeps accessibility zoom and authored CSS `zoom` as related but
distinct factors. Display-list coordinates remain page-layout coordinates:
fixed CSS lengths, font metrics, natural replaced-element sizes, translations,
radii, and filters have the cumulative authored subtree factor baked into
them, while raster applies the tab's accessibility factor once to the complete
list. Auto widths are already expressed by their containing block and are not
multiplied. A BlockLayout's protected zoom field stores the total factor so a
computed-style change invalidates descendant geometry and paint/hit effects
read the same generation.

Replaced `<img>` elements retain a CSS/attribute-selected element box separately
from decoded bitmap geometry. Images and iframes share one unscaled
replaced-size resolver: supported CSS pixel dimensions override their matching
HTML attributes, two specified axes win over `aspect-ratio`, and a preferred
ratio derives only the missing axis. `auto <ratio>` gives an unloaded lazy
image a stable fallback ratio, then switches to its natural ratio once decoded;
plain `auto` retains natural-image and 300x150 iframe defaults after those
resources exist. An unloaded image has a zero used value for every unspecified
axis, rather than inventing a square intrinsic box.
Authored subtree zoom is applied only after both axes are resolved, and the
same iframe result seeds its child Frame viewport before later parent paint
republishes exact placeholder geometry. `object-fit` then resolves a centered
visible destination for `fill`, `contain`, `cover`, `none`, or `scale-down`
and emits an optional fractional source-pixel crop where content crosses the
box. The fractional boundary matters for low-resolution images and is copied
unchanged through display-list and raster-snapshot owners. Paint/compositor
bounds use the visible destination, while the synchronous display item retains
the full element box for hit testing; source provenance is still cleared at
the worker snapshot boundary. Authored dimensions therefore reserve their box
before a lazy request completes; one dimension plus a usable aspect ratio
reserves both axes. One dimension without a usable ratio reserves just that
axis, and without either dimension the pre-load box is zero space. Post-decode
layout uses the natural bitmap ratio and size.

An iframe placeholder carries its numeric authored effective zoom alongside
its already-scaled rectangle. The child Frame stores that factor independently
of DOM provenance; after parent style, Tab updates it before the post-order
layout pass and rescales the prior viewport by the factor delta. Child layout
uses the scaled viewport coordinate space, while conditional CSS divides by
the inherited factor to recover the iframe's unscaled CSS-pixel media width.
When parent layout publishes a different iframe rectangle during composition,
the Frame installs both dimensions and synchronously dirties its layout subtree
before scheduling a follow-up media/style generation. The current commit may
contain the prior child snapshot, but the next frame cannot reuse its geometry
or exact-width rule set. The numeric factor may cross composition boundaries;
it does not extend any DOM or layout-object lifetime.

DOM focus is also a synchronous, generation-bound operation. JavaScript
`Node.focus()` crosses the host boundary with a numeric handle rather than a
raw Node pointer. The tab worker first completes pending style/layout/paint,
then requires the target to appear in that frame generation's focus-bounds
snapshot before reading its position or scrolling it into view. It clears the
old focus state before dispatching target-only blur events, re-renders and
re-resolves the handle after listeners may mutate the DOM, and only then
installs focus and dispatches the target-only focus event. Focus/blur listener
dispatch never retains a raw Node across another listener: the blur pass
snapshots handles for every old focused frame before JavaScript runs. Because
the native focus callback is entered while the JavaScript mutex is already
held, its handle and event operations use callback-only lock-aware entry points;
ordinary lock-taking DOM APIs would deadlock there. Page focus intent crosses
back to the UI thread as stable Tab identity so Chrome's private DOM/layout is
mutated only by the native-window tick.

### DOM and source buffers

Elements store children by value in `ArrayList(Node)` and store raw parent and
layout pointers; see `Element` and `Node.appendChild` in
[`src/document/parser.zig`](../src/document/parser.zig). Parser-created tag,
text, undecoded attribute, and CSS value slices generally borrow their input
buffer. Attribute values containing recognized character references are
decoded into strings owned by that `Element`; text references remain escaped
in the source-backed DOM and are decoded once during layout. Diagnostic DOM
serialization re-escapes decoded attribute values so quoted output remains
well-formed. JavaScript `innerHTML`/`outerHTML` reads use the live DOM rather
than retaining the last assigned source: current attributes are sorted,
quoted, and escaped, ordinary descendants are recursive, and void-element
outer HTML ends after its start tag. Source-backed text is copied verbatim to
avoid double-escaping its retained character references. Therefore:

1. the decoded HTML source must outlive the complete DOM;
2. a stylesheet source must outlive all rule property names and values parsed
   from it;
3. an address of an `ArrayList(Node)` element is valid only until a structural
   mutation can relocate or remove that element;
4. all DOM-derived indexes and handles must be invalidated or updated in the
   same transaction as structural mutation.

The parser acknowledges child-array relocation by fixing parent pointers after
tree construction rather than during `appendChild`. That repair only updates
parent pointers; it does not repair every other retained `*Node`. Because the
inspection `Page` returns its root by value, dump callers repair parent pointers
again after the returned page reaches its stable stack address and before
layout paint performs visited/source ancestry walks.

Supported in-place structural mutations use a synchronous invalidation
boundary. `innerHTML` stages its replacement children and backing string,
marks the target layout dirty, clears every current DOM style field's raw
subscriber map while all endpoints are alive, then invokes the frame's
DOM-mutation callback before destroying the old children or replacing their
array. The first native contenteditable child append invokes the same Tab seam
before a fallible
capacity change and performs the same subscriber clear. JavaScript
`createElement` results are heap-stable roots owned by their window while
detached. `appendChild` and `insertBefore` accept those
detached roots, snapshot immediate-child handle bindings, enter the same
invalidation seam, reserve capacity, and then transfer the new owner into the
by-value child array while rebinding every relocated handle. `removeChild`
preallocates the inverse heap-stable owner, enters the seam, moves the direct
child out of attached storage, and rebinds the removed root plus every shifted
sibling. The detached subtree keeps its owning DOM resources and handles, but
clears layout back-pointers and dirties retained style fields. Reattachment
registers inherited-style dependencies against the current parent before a
frozen dependency read. That seam retires the frame display list and DOM-keyed
bounds, clears the accessibility tree and
pending composited node updates, and retires the active browser draw list,
layers, and committed display list under `Browser.lock`. It then destroys the
mutating frame's complete `DocumentLayout` while the old DOM still exists, so
the full replacement render constructs a fresh dependency graph. Dirty flags
and an animation-frame request are published before the mutation proceeds, so
allocation failure still rebuilds the retired state. A focused mutation root
survives; focus is cleared only when the focused node is a strict descendant
that the replacement removes. After the mutation has installed its final child
array, repaired parent pointers, and rebound JavaScript handles, a paired
completion callback runs before JavaScript resumes. Each iframe Element's
numeric window ID moves with the by-value Node, allowing that pass to repair the
Frame's raw `frame_element` borrow without dereferencing its old address.
Unmatched child Frames are unregistered and recursively destroyed immediately;
if a same-origin child shared the current Js host, the host restores the
mutating parent window after clearing the child realm's native bindings.

### CSS rules and invalidation fields

`CSSRule` owns selector allocations and property-map storage. Declared property
keys and values borrow the parser's source string; shorthand expansions can
also use static keys and defaults. See `CSSParser.word`, `CSSParser.value`,
`CSSParser.body`, and `CSSRule.deinit` in
[`src/document/css_parser.zig`](../src/document/css_parser.zig). Frame rules
borrow the browser's default rules and own document rules, distinguished by
`CSSRule.owned`.

Concatenated tag/class selectors, such as `span.announce.urgent`, own a flat
`SelectorSequence` of atomic selectors. All members match against the same DOM
node, and their specificity priorities are summed. A single tag or class keeps
its direct representation without allocating a sequence list.

Whitespace-separated descendant selectors own a flat, source-ordered list of
simple selectors instead of a recursive selector tree. Matching receives a
borrowed ancestor slice ordered from the document root through the immediate
parent, then walks that slice and the selector list backward once. Both style
traversal and JavaScript selector queries must preserve this order so matching
remains O(n + d).

Relational selectors such as `div.card:has(span.badge)` own separate anchor and
strict-descendant simple selectors. Before style matching or a JavaScript
selector query, a post-order traversal propagates each descendant match upward
and stores qualifying ancestors in an ephemeral `HasMatchCache`. For H distinct
relational selectors and N DOM nodes, preprocessing costs O(HN) time and up to
O(HN) cache space; subsequent matching costs average O(H) per element, or
average O(1) per element for each fixed selector. Style passes with relational
rules rebuild the cache, while selector-relevant mutation hooks conservatively
dirty the changed element and its ancestor chain in O(depth) time. The cache
borrows DOM and selector pointers only for the synchronous traversal and must
not survive either tree or rule mutation.

Style and layout values use `ProtectedField`. A dependency registers a raw
target pointer and callback in the dependency's `invalidations` map.
`ProtectedField.deinit` only destroys the field's own map; it does not remove
that field from maps in its dependencies. See `addDependency`,
`addInvalidation`, `notify`, and `deinit` in
[`src/core/protected_field.zig`](../src/core/protected_field.zig).

Supported structural DOM mutation uses a coarse lifetime boundary:
`clearStyleInvalidations` drops every raw subscriber from every installed DOM
style field before child storage moves or retires, and the already-required
full style/layout pass rebuilds live edges. This prevents surviving parent
style sources from notifying destroyed child-style or layout subscribers on
these paths without pretending to provide general per-edge unsubscription.

Inherited style fields establish these edges between parent and child DOM
styles in [`src/document/parser.zig`](../src/document/parser.zig). Layout fields
establish similar edges between document, parent, previous sibling, and child
layout objects in [`src/browser/render/layout.zig`](../src/browser/render/layout.zig).
During an active incremental layout traversal, child metrics can notify the
parent aggregate that is already being recomputed. Document, block, and line
owners suppress that reentrant owner-wide callback while their `in_layout`
guard is set; the individual aggregate remains dirty until the same traversal
publishes its final value. This keeps stable parent x/width fields readable by
later siblings without dropping an external invalidation.
The synthetic default-parent style used at the root is ephemeral to one style
pass: root fields read its defaults directly and never register dependency edges
to it.
The general unresolved contract is how an individual invalidation subscriber
unregisters before its address becomes invalid outside that full structural
rebuild boundary.

### Layout, fonts, images, and display items

`DocumentLayout` retains both a shallow `Node` copy and the original `*Node`.
Individual block layouts also retain node pointers and install
`layout_ptr`/`layout_mark` back-pointers on elements; see
[`src/browser/render/layout.zig`](../src/browser/render/layout.zig). Layout
therefore borrows the DOM and must be destroyed before it.

`ImageLayout.pixels` borrows `ImageData.image.rawBytes()`. `FontManager` owns
font handles and dimensionally exact RGBA glyph bitmaps. A copied `Glyph`
borrows its cached pixel slice; it does not transfer ownership. Its
`pixel_mode` distinguishes a tintable alpha mask from a native-color bitmap.
The cached `Glyph` does not store the source grapheme slice, so transient input
text is not retained as glyph metadata.

CSS background paint borrows the same Element-owned decoded-image shape but
does not retain another pointer in block or control layout state. Paint reads
the live resource, emits color then image before content, and scopes all three
under the element's effects. `background-size` resolves intrinsic `auto`, px,
percentage, contain, and cover geometry in authored layout space. The image
command's optional half-open source rectangle crops oversized output at the
right/bottom border; raster snapshots copy the underlying complete bitmap and
preserve that numeric crop.

An Element lazily owns a heap-stable canvas pointee when JavaScript first calls
`getContext("2d")`. z2d Context retains the address of the Surface inside that
pointee, so DOM child-array moves transfer the pointer but never copy the
backing object. Canvas width/height attributes select unzoomed bitmap pixels
with 300x150 defaults; layout applies authored/accessibility zoom only to the
replaced-element box. Assigning either dimension resets pixels and drawing
state even when the numeric size is unchanged. Canvas drawing is serialized
with JavaScript and layout on the tab worker. A cached layout command can
predate lazy context allocation, so each provenance-backed paint clone resolves
the current Element backing and converts its live premultiplied z2d pixels into
one independently owned straight-alpha `.canvas` command. Subsequent script
drawing therefore cannot race or rewrite a committed/browser-worker generation;
a context-free canvas uses an empty, transparent snapshot that raster accepts
without indexing.

Display-list container ownership is recursive: `.blend` and `.transform` own
their child slices, and `.blend` owns its copied blend-mode string. A blend's
copyable `blur_radius` marks a CSS filter wrapper without adding another owner.
See `DisplayItem.freeList` in
[`src/browser/render/display_list.zig`](../src/browser/render/display_list.zig).
`BlockLayout.display_list` is a persistent paint cache and recursively owns
any such containers stored in it. Painting a frame deep-clones cached items
before wrapping them in effects or transferring the resulting snapshot; frame
retirement must therefore free only the clone and leave the cache reusable for
paint-only animation frames. Relayout recursively releases cached containers
before replacing the cache.
Primitive entries are not self-contained:

- `.image.pixels` borrows decoded image memory;
- `.canvas.pixels` owns an immutable allocation and every deep command clone
  owns its own copy;
- `.glyph.glyph` borrows a `FontManager` pixel resource;
- `.iframe.node`, `.blend.node`, and `.transform.node` borrow DOM identity;
- composited-layer entries borrow layer allocations.

These leaf resources must outlive every frame-side and browser-side display
list that references them.

An uncomposed frame item may additionally carry `DisplayItemSource`. Its
layout pointer identifies the actual stable generator for that command, while
its optional node pointer identifies the originating DOM node. Inline commands
produced by the transient line buffer use the containing `BlockLayout` as the
generator and retain each `LineItem.node_ptr` as their node identity. A typed
resolver consults that generator for every activation and rejects a fragment
node outside its DOM subtree; anonymous blocks validate against their retained
inline roots. Source metadata is never serialized by display-list dumps and is
cleared recursively from the separately owned list composed for
`Browser.commit`.

Rich buttons remain one atomic item in their surrounding inline line, but
their descendants are laid out through a temporary block subtree in local
coordinates. Its paint commands and interactive bounds are transferred into
the surrounding persistent block, with command sources rebased onto that
stable layout origin before the temporary tree retires. The button's outer box
unions structural and painted descendant bounds, so tall blocks, wrapping
text, and translated overflow increase its inline dimensions instead of
spilling into following content. Descendant paint provenance remains precise:
an embedded link or input is activated before the ancestor button, while an
uncovered button pixel activates the button itself. HTML parser recovery keeps
a later button start out of this case by implicitly closing the active button.
Because `ProtectedField` cannot unsubscribe, no field owned by this temporary
tree or a short-lived inline embed record registers with a DOM style or the
persistent containing block. The temporary records copy current values, while
their DOM style sources register the containing BlockLayout's height directly
as the stable invalidation target. That persistent owner rebuilds the records
when any descendant style changes.

`DisplayItem.hitTestDevice` is a pure walk over the retained frame list. It
visits items in reverse paint order, inverts translation transforms, treats
`dst_in` masks as clipping operators rather than click targets, and checks
primitive paint geometry. A rounded rectangle uses its clamped corner circles,
so a point inside its containing rectangle but outside a rounded corner misses
that item and the walk may select painted content underneath. The complete
paint group of an ordinary rounded element carries an owning blend's
non-painting `hit_clip`; inputs and rich buttons preserve authored radii by
emitting the same primitive and grouping their payload the same way. Thus text,
control glyphs, and rich descendants cannot restore a rectangular hit region,
and no composited visual mask is required. Native mouse clicks and completed
touch taps retain the exact device point and
the committed zoom snapshot; CSS positions and translations use the same
truncating scale rule as raster, while cached glyph widths/heights remain exact
device bitmap dimensions. `Frame.click` normalizes the hit to its painted
element and dispatches one primary click there, including for elements with no
built-in action. The event bubbles over a target-to-root handle snapshot;
iframe hits instead enter the child document and scale the combined
`top - child_scroll` translation once, matching composition at fractional
zoom. Before JavaScript runs, a clickable ancestor's stable handle is captured;
after listeners return, the frame resolves that handle against the attached
document before performing anchor, input, button, or contenteditable behavior.
Thus structural listener mutation cannot leave the default-action path holding
a relocated raw Node pointer. `stopPropagation` controls only ancestor
delivery, while `preventDefault` cancels that resolved browser action.
Compositor-only opacity and translation animation updates also mutate the
retained effect wrapper before the same update is committed, so hit testing
tracks the visible animated position and opacity. The committed command tree
uses the DOM address only as a UI/tab-thread lookup key. Raster snapshots clear
that borrow and retain a numeric compositor ID; no DOM pointer crosses to the
raster worker. Effects that cannot be represented as a top-level retained plane
fall back to a full raster.

`DocumentLayout.hitTest` is the complementary structural point query. The
document converts the page point to its own coordinates once; block, line, and
text objects then subtract only their offset from the parent. Blocks invert
their live CSS translation, add their live element scroll before entering
content, apply rounded/overflow clips locally, and visit children in reverse
paint order. Inline-mode blocks do not yet retain line/text objects, so they use
their provenance-bearing cached paint commands as an exact local leaf. Content
clicks still require a painted-command hit—preserving fragment gaps, glyph
bitmap geometry, rich controls, and masks—but always perform the layout query
and use it when painted provenance cannot resolve an originating node.
Run this layout query only on the serialized tab worker; UI-thread accessibility
continues to consume its committed root-relative bounds snapshot rather than
borrowing a concurrently rebuilt layout graph. Neither hit-test path rebuilds
every descendant's absolute bounds.

Block painting preserves layout and DOM storage order but visits immediate
children through a retained stable permutation of their DOM indices. A non-static
positioned block receives its parsed signed integer `z-index`; static blocks,
lines, missing values, and invalid values use zero. Ascending `(z-index, DOM
index)` order drives paint, and the exact reverse drives structural hit testing,
so ties retain source order and the visual topmost child is queried first. The
permutation refreshes at paint and stays with that retained layout/display
generation; input never sorts or allocates. Each child subtree applies the
same rule recursively. The subtree remains grouped
under its parent's transform, opacity, blur, clip, and scroll wrappers, making
nested z-index local to that parent rather than detaching commands from their
effect and lifetime owners.

Layout-derived link and iframe bounds no longer decide click targets. Focus,
accessibility, and fragment bounds retain their existing roles.

CSS blur is represented by an inner composited blend around the element's
complete painted subtree. Its premultiplied RGBA surface is convolved with a
separable Gaussian kernel and outsets visual bounds by three standard
deviations. An element scroll offset first translates only the content while
leaving its background fixed. The surrounding effect group then preserves CSS
paint order: blur, overflow/border-radius clipping, group opacity and mix
blending, and CSS translation last. Effect groups remain distinct because a
blur or unbounded `dst_in` mask cannot safely consume neighboring pixels.
Layer opacity scales all premultiplied channels together, and the layer's blend
operator is applied only when the completed surface is placed. Hit testing
continues through the original child commands, so the blur's visual haze does
not enlarge interactive geometry.

A `DrawCompositedLayer` command borrows its retained layer and stores a
draw-local opacity multiplier independently of the layer's live compositor
opacity. An opacity-only `Blend` around that single draw folds its alpha into
the command copy; final placement multiplies both scalars while reading the
cached premultiplied pixels once. The layer surface and its shared animation
state are not mutated. Masks, filters, blend operators, and multi-command group
opacity keep their isolation boundary because distributing opacity across
those children would change output.

The per-window raster worker keeps either one bounded assembled tab surface or
an ordered compositor-plane cache. `scroll.zig` chooses a device-pixel interest
region no taller than four native window heights, with one viewport of
scroll-back headroom where page bounds permit. Without separable effects,
raster translates page commands by that region's page-space start and publishes
the coordinates only after all fallible drawing succeeds. Before the first
document commit, an active tab may have no display list; that state renders as
blank content after the worker clears its tab cache. Cache validity is required
only when a task represents committed tab content. With top-level composited
opacity or translation effects, static strata become ordered planes
cropped to their painted intersection with the interest region, and each
animated subtree gets its own plane. A plane with at most three cheap
rect/rounded-rect/line/outline leaves owns a separate pointer-free
`RasterSnapshot` instead of an RGBA surface. Its raster phase is a no-op; final
draw replays those commands in plane order with the current scalar opacity and
translation. Glyphs, images, blur, blend modes, and multi-command grouped
opacity remain surface-backed because replay would be expensive or would
change group semantics. Static strata may
merge backward across stable dynamic planes when their tight painted bounds are
disjoint. A merge is rejected when its union would exceed 1,048,576 device
pixels (about four MiB of RGBA storage), preventing far-apart chunks from
creating a mostly transparent allocation; an intrinsically larger single chunk
is still rasterized. A short-plane merge either installs another independently
owned short snapshot or transactionally promotes the combined commands to a
surface. Surface expansion and promotion leave the prior plane generation
intact on allocation or draw failure. An active transform instead
enters assume-overlap mode for the raster generation: every later stratum stays
after that plane even when its initial bounds are disjoint, because a later
scalar translation can make them overlap. This conservative barrier preserves
CSS paint order without repeating overlap testing, compositing, or raster on
every animation frame. Later pointer-free scalar updates change plane
opacity/translation; the worker assembles surface planes and replays short
planes beneath chrome without rerastering their pixels. Complex masks or
unsupported nesting deliberately use the assembled surface fallback.

Final software draw moves cached page pixels by `region_start - root_scroll`
beneath chrome. z2d has no public `clipRect`, so final composition slices source
and destination pixel rows to the content viewport, providing the same hard
clip as the book's Skia operation. A root scroll whose complete viewport
remains in the published region queues a draw-only worker job without cloning
commands or invalidating compositor planes. Crossing an edge rerasterizes a new
region, while display-list replacement, resize, zoom, content-height change,
and structural retirement invalidate the cache.

Viewport smooth scrolling is a separate, allocation-free animation owned by
the target `Frame`. On serialized Up/Down input, the tab samples the authored
body's non-inherited computed `scroll-behavior`; `smooth` creates or retargets a
250ms clock-based ease-out interpolation, while `auto` and reduced-motion mode
use the immediate path. Repeated keys accumulate from the pending destination
but restart interpolation from the currently displayed offset, avoiding jumps.
The tab advances every live frame's value alongside CSS/JavaScript animation
callbacks. A root step commits only the scalar scroll offset, so the Browser
can reuse its interest-region surface and draw without raster until an edge is
crossed. Child iframe placement is encoded in the composed command tree and
therefore repaints during its smooth scroll. Direct wheel/voice or focused
overflow scrolling cancels a pending viewport interpolation; navigation and
fragment jumps retire it with, or explicitly clear it from, the Frame.

Basic text direction is resolved per inline block through the acyclic layout
parent chain. The CLI `-rtl` flag supplies the fallback direction; the nearest
block ancestor with `dir=rtl` or `dir=ltr` overrides it. Glyphs are measured and
wrapped in source order, then the completed line is shifted to its selected
edge, so English remains left-to-right while an RTL-directed line grows from
the right. This is intentionally not a Unicode bidi or contextual-script
shaping implementation; `dir=auto` currently inherits the fallback.
The same completed-line alignment step centers every line beneath an `h1`
whose class-token list contains `title`. Title alignment is resolved from the
layout parent chain and remains active across explicit and automatic line
breaks.
Superscript state likewise follows DOM recursion and layout ancestry rather
than borrowed DOM-parent pointers. Superscript glyphs carry their placement
marker into line flushing, which aligns their tops without moving the normal
text baseline.
Small-caps state follows the same scoped DOM-recursion and layout-ancestry
model for `abbr`. Lowercase ASCII graphemes select an uppercase bold glyph at
four-fifths of the inherited size, while other graphemes and following
siblings retain their inherited text styling.
Preformatted state follows that scoped model for `pre`. Its text retains source
spaces and explicit CR, LF, and CRLF line breaks, advances consecutive empty
lines, suppresses viewport wrapping, and selects the monospace font while
allowing nested elements to change weight, slant, color, and size normally.
The inherited `font-family` computed value selects either the proportional or
platform monospace face for Latin text. Common Courier and monospace aliases
map to that platform face, while CJK, symbol, and emoji graphemes continue to
use their specialized fallback categories. Each loaded font owns its glyph
cache, so identical grapheme/style/size keys remain isolated between selected
families.
Block `width` and `height` computed values remain borrowed style slices and are
registered as dependencies of their DOM-backed layout box. A non-negative
pixel width replaces the available content width before descendant layout; a
pixel height replaces the content-derived height after descendant layout.
`auto`, invalid values, and synthesized anonymous blocks retain the existing
automatic algorithm. Content is not clipped by a fixed height unless the
separate overflow behavior requests clipping.
For fixed-height `overflow: scroll`, layout also publishes the natural content
height and fixed client height into scalar state on the live `Element`,
preserving and clamping its `scroll_y` across layout generations. Repaint reads
that live scalar, translates only the box's content commands, and scopes them
under a square or rounded clip; nested wrappers compose recursively.
The non-inherited `display` computed value likewise remains a borrowed style
slice. Layout treats `block` children as separate block boxes and groups other
children into anonymous inline runs; the browser stylesheet, rather than Zig
tag tables, supplies HTML's block defaults. Each block layout registers direct
child display fields against its tree-version field so a later style change
rebuilds grouping without retaining an additional DOM or string borrow.
Inline `<style>` text is copied out of the DOM into the same frame-owned source
generation as decoded linked stylesheets. Both forms are parsed in DOM order,
and the stable specificity sort preserves that order among equally specific
rules. Inspection pages and interactive root/iframe loads use the same source
ordering. This copy lets accessibility-driven rule rebuilds reparse every
retained author sheet for that frame without making CSS rule lifetime depend
on DOM text slices.
CSS shorthands expand while declaration bodies are parsed, before cascade and
computed-style resolution. Expanded property names and defaults are static;
other values borrow sub-slices of the stylesheet or inline-style buffer.
Declaration order is preserved so shorthand and longhand overrides have normal
last-write behavior without introducing a second owned value representation.
Each expanded longhand also retains declaration-local `!important` metadata.
The cascade compares each matching property independently using selector
priority plus 10,000 for important declarations; exact ties retain source order.
Inline declarations use a base specificity of 1,000, so an author-important
declaration beats a normal inline value while an inline-important declaration
normally wins among author declarations.
Soft-hyphen wrapping temporarily transfers the post-break `LineItem` suffix
out of the active line before flushing its prefix. Glyph entries only borrow
font data, but embedded input, image, and iframe payloads retain single
ownership throughout the transfer. The suffix is then rebased and transferred
back to the next line; it must never be shallow-copied and independently freed.

### Network responses and URLs

`HttpResponse.body` in [`src/network/url.zig`](../src/network/url.zig) is an
untagged slice with no destructor. `Browser.fetchBody` returns allocated bodies
for file and HTTP paths, a slice into `Url.path` for `data:`, and borrowed data
for `about:`. Callers currently infer ownership again from the URL scheme.

The BrowserSession-owned `HttpCache` in
[`src/network/cache.zig`](../src/network/cache.zig) stores owned copies of
decoded GET/200 response bodies, CSP headers, and final redirect URLs. Cache
entries also retain the parsed Referrer-Policy enum. Cache hits duplicate body
and header data and restore the policy before returning, so they preserve the
existing caller-owned HTTP response contract and the document's later request
behavior. Entries with `max-age` use the monotonic awake clock; `no-store`,
malformed directives, and unknown directives bypass storage. Responses without
`Cache-Control` remain cached for the current browser session, matching the
exercise's simplified model.
`BrowserSession.network_lock` serializes only cookie/cache access across tabs
and native windows without nesting the visited/bookmark mutex. Cache-hit
responses and Cookie request headers are copied while locked, so the shared
maps may change safely while independent `std.http.Client` requests are in
flight.

Every document Frame stores the Referrer-Policy parsed from its response.
Navigation, element and CSS-background images, iframes, scripts, stylesheets,
and XHR pass both that policy and the source URL into the network layer.
Referer generation omits fragments;
`no-referrer` suppresses it for every destination and `same-origin` suppresses
it when scheme, host, or port differs. The source URL remains a separate
synchronous request-context borrow even when the header is suppressed, because
SameSite cookie selection still needs the actual initiator. Async XHR clones
the source URL and copies the policy before leaving the document generation.

Cross-origin XHR derives an independently owned canonical origin from its
copied referrer, sends it in the HTTP `Origin` header alongside any eligible
target-host cookie, and bypasses the ordinary response cache. The final
response carries an owned `Access-Control-Allow-Origin` copy only on this
path. Exact-origin and wildcard values authorize body delivery; a missing or
mismatched value causes synchronous XHR to throw and asynchronous XHR to free
the response without queueing `onload`. Same-origin XHR sends no Origin header
and needs no response opt-in. Authorized synchronous and asynchronous response
strings move into Kiesel's traced heap before their callback/task buffers are
freed, because its ASCII cache may retain input bytes. CSP remains an earlier
request-side gate.

`Url` wraps an owning `ada.Url` and has an explicit `free` method. Its component
slices borrow that owner, except for separately allocated data-URL storage.
Ordinary Zig value copies of `Url` are shallow. Treat `Url` as move-only unless
a function is explicitly documented to borrow it, and use `Url.clone` when an
independent owner is required. `clone` rebuilds independent Ada and data-URL
storage. Root and child navigation keep the prior URL owner alive through the
synchronous fetch; async XHR clones its target and referrer before leaving the
tab worker.

Relative references are resolved by Ada against the complete href. Fragment
accessors borrow Ada storage, and same-document comparison ignores only the
fragment component, retaining query identity. HTTP cache keys and requests omit
fragments; after a network response or cache hit, the final navigation URL
inherits the requested fragment unless a redirect destination supplied one.
URL serialization uses the Ada href so chrome retains query and fragment text.

Document-replacing inputs use `Url.initForNavigation` or
`Url.resolveForNavigation`. These preserve `OutOfMemory`, but turn URL syntax,
data-payload, and unsupported-scheme failures into an independently owned
`about:blank`. Strict `init`/`resolve` remain the subresource contract so a bad
stylesheet, image, or script URL does not replace its containing document;
attempting to fetch an unsupported scheme through that strict path returns
`UnsupportedScheme`. The borrowed `about:blank` response body is empty; HTML
parsing supplies the normal empty document structure.

Top-level HTTP navigation uses `fetchBodyWithFinalUrl` to receive an owned URL
for the final redirect destination. `loadInTab` moves that value into the
existing navigation URL pointer before parsing subresources or preparing
history, so the installed frame, the independently cloned history request,
relative URLs, and chrome all use the final destination without adding URL
ownership to ordinary subresource responses. A replay clones the retained
request and lets the installed Frame own any newly resolved final destination;
the immutable action remains a safe future replay source even if redirect
policy changes between traversals.

`view-source:` now replaces the wrapper Ada URL with the parsed inner Ada URL
before exposing the inner component slices. That inner URL is the one released
by `Url.free`; see `Url.init` in [`src/network/url.zig`](../src/network/url.zig).

## Thread ownership and synchronization

### Main/UI thread and raster workers

The process main thread owns every Browser's input dispatch, chrome rebuild,
render-job snapshot, and SDL presentation phases. Each Browser owns a separate
named `TaskRunner` for z2d raster and software draw. In interactive mode,
BrowserApp is the sole SDL event poller and text input owner. It derives the
native ID from key, window, text-editing/text-input,
mouse, drop, and user event payloads, ignores stale IDs, and forwards each
event only to its addressed Browser. Nonrepeating Ctrl+N from a live source
creates an `about:blank` native window; allocation or renderer failure logs and
leaves existing windows alive. Window-close events remove only their addressed
entry, SDL quit is global, and Escape routed through any live Browser is the
documented global shortcut. After event dispatch, the App broadcasts shared
session generations and ticks every window. Each tick schedules requested
tab-worker animation work before queueing the previous commit for its raster
worker, so tab work and software presentation can overlap while the UI thread
returns to SDL event polling. In
screenshot mode a standalone Browser instead runs a windowless quiescence loop
and exports the software root surface directly. Page workers never mutate the
tab collection: a middle-click resolves its link target on the serialized tab
worker, transfers the owning URL into `Browser.pending_new_tabs` under
`Browser.lock`, and the containing Browser's tick drains that queue before
creating and activating tabs in the same native window.

The UI thread rebuilds Chrome, then holds `Browser.lock` only while cloning the
chrome and committed page command trees. `RasterSnapshot` owns every recursive
container and blend-mode string, copies each borrowed font glyph bitmap and
image byte buffer, and converts composited DOM identity to a scalar numeric ID.
The queued job therefore contains no layout, DOM, FontManager, ImageData, or
chrome-generation borrow. Full-raster jobs may rebuild the worker-owned ordered
plane cache; draw-only jobs carry only scroll geometry and opacity/translation
updates for those planes. Tab commits, structural mutation, navigation,
scrolling, and input may continue while either runs. A newer dirty commit or a
window/tab mismatch causes the completed result to be discarded; otherwise the
UI thread swaps in the owned z2d root surface. The job queue, snapshots, caches,
and surfaces use the thread-safe SMP allocator; Browser records the current
root surface's allocator when ownership transfers.
The worker never calls SDL. Texture lock/upload, renderer copy, `present`, native
window/title/dialog operations, event polling, and resize-time texture
creation/destruction remain on the Browser/UI thread. Input callbacks only
publish dirty flags and queued tab work; they do not synchronously raster or
present.
`queueNewTab` transfers ownership only when append succeeds; `newTab` consumes
the URL on entry so every creation and scheduling failure has one clear owner.
Root navigation also copies the first DOM `title` into tab-owned sentinel
storage under `Browser.lock`. The App tick applies each window's dirty active
title to its SDL handle; switching tabs uses the same activation path and marks
it dirty.
Chrome's Back and Forward handlers read only atomic availability snapshots and
enqueue a history task. The worker computes the target again before loading,
so a click based on a stale disabled/enabled snapshot is harmless.
History entries are heap-stable owners of a URL, explicit GET/POST method,
independent POST-body and frame-path copies, and the recursive request snapshot
from before the navigation. A navigation prepares the full entry and list
capacity before retiring the current document, then appends it only after the
replacement document is ready. Truncating entries recursively frees their
resulting request and prior-subtree snapshot.

A GET traversal is replayed directly on the tab worker. Back restores the
current entry's prior target subtree; Forward reapplies the next entry's
resulting request. If that exact operation needs a POST—possibly in a nested
subtree restored with its parent—the worker publishes a tab pointer, target
index, and history generation under `Browser.lock`. The interactive SDL thread
consumes that request and displays one native modal confirmation without
holding the lock. Cancel schedules nothing. Resubmit queues a task back to the
originating tab, which validates the adjacent target and generation and moves
the index only after every required request succeeds. Same-document history
actions never prompt or resend their retained POST metadata. Tab switches,
shutdown, stale generations, dialog failures, and headless operation all
cancel rather than replaying state-changing data.
Address-bar submission is the sole URL-or-search policy boundary. Chrome trims
the input, preserves explicit schemes and obvious bare hosts, and otherwise
constructs a Google query using `+` for whitespace and percent escapes for
unsafe bytes. The result then enters the normal navigation path; document links
continue to use strict relative URL resolution and can never become searches.
Chrome owns an address-bar byte cursor in the inclusive range from zero through
the buffer length. Interactive SDL text input admits only printable ASCII, so
Left and Right move one byte, insertion occurs at that position, and Backspace
removes the preceding byte without introducing a second Unicode boundary rule.
Focus, blur, and successful submission reset the cursor; chrome rasterization
measures the glyph prefix before the cursor to place the visible caret. Address
focus takes precedence over retained DOM focus for text, Return, Space, and
Backspace routing, including editing operations that are no-ops at a boundary.
Focus ownership also has a visual handoff: a chrome click queues `Tab.blur`
before chrome selects its new focus, while content clicks, keyboard traversal,
and accessibility activation call the same blur before selecting a DOM node.
Blur clears every frame-local focus and
`is_focused` marker in the tab, resets accessibility focus, and requests paint
when it removed a content cursor. The chrome path never mutates those DOM
borrows directly.
Tab and Shift-Tab traversal share that same handoff across the whole frame
tree. The root frame and each descendant frame form preorder focus groups:
DOM-order sequential focus stops in one document are exhausted before its
child frames, frames with no stops are skipped, and only the end of the full
tree wraps to the opposite edge. If a pointer selected a frame background
without selecting an element, traversal begins at that frame's requested edge;
an empty selected frame advances to the next non-empty group. No flattened
list outlives the synchronous key task: collected `*Frame` and `*Node` values
remain short-lived borrows, and `focusElement` performs the existing tab-wide
blur before installing the next frame-local focus.
Primary content clicks also retain the innermost ancestor whose layout marked
it as an element scroll container. Up/Down tasks mutate that element offset on
the serialized tab worker, repaint without relayout, and try enclosing scroll
containers when the focused one is at its boundary before falling back to the
focused frame/root scroll model. Blur, navigation reset, and the synchronous
structural-mutation boundary clear this borrowed scroll-focus pointer.
Once Return is routed to page content, `Tab.enter` distinguishes text entry
from generic activation: a focused text input dispatches `keydown`, finds its
containing form, dispatches the cancelable `submit` event, collects the current
named input values, and schedules the existing form-navigation path. A missing
form action resolves against the current document. The missing/invalid method
default is GET: its encoded data replaces the action query and the scheduled
network request has a null payload. An explicit case-insensitive POST instead
transfers the owned encoded buffer to the load task after successful scheduling.
Checkboxes keep no parallel widget state: the boolean state is the presence of
the DOM `checked` attribute. Layout reads it to paint the mark, and a default
activation toggles it only after the cancelable click event permits the action.
When encoding successful controls, unchecked checkboxes are omitted; a checked
checkbox contributes its explicit `value`, or the static default `on` when that
attribute is absent. The `checked` key inserted by activation and its empty
value are static slices, while parser-provided attributes continue to borrow
the document buffer.
Hidden and password controls likewise keep one authoritative DOM `value`.
Hidden inputs remain part of successful-control form encoding but are excluded
before inline measurement, so they produce no geometry, paint provenance,
focus stop, hit target, or accessibility node. Password inputs follow the
ordinary text-entry event/edit/Return path; input paint substitutes one `*`
glyph per source grapheme while form encoding retains the original value.
Accessibility naming and speech never copy that password value.
Space continues to use only focused-element activation, and a text input outside
a form does nothing.
Primary same-document fragment links stay on the tab worker: they resolve the
new URL, append a non-document-replacing joint-history action for either the
root or iframe path, replace that Frame's independently owned current URL,
apply the clamped layout target, and request a paint commit. Back/Forward
reapply only the URL/scroll action and never resend retained POST metadata. The
existing DOM, JavaScript state, form controls, descendants, and document
generation remain intact. Middle click still transfers the resolved URL to a
new tab instead.

Window resizing preserves that ownership boundary. The main thread allocates a
complete replacement generation of the root/chrome/bounded-tab z2d surfaces
and SDL texture before retiring the live generation, invalidates the tab
interest coordinates, updates chrome geometry, and then queues viewport
snapshots to each tab. Obsolete drag-resize snapshots are
discarded by generation. A tab worker updates its root-frame viewport, marks
every frame layout dirty, re-clamps scroll, and requests the active tab's next
animation frame; it does not mutate native render targets.

### Tab worker

Each `TaskRunner` in [`src/runtime/task.zig`](../src/runtime/task.zig) owns a
queue of `Task` values and executes one task at a time on its worker. A `Task`
owns its opaque context through one of these paths:

- execute `run_fn`, then call `cleanup_fn`; or
- if discarded before execution, call `cleanup_fn` while clearing the queue.

Each accepted task also borrows a stable diagnostic name from its producer.
The worker emits a matched Chrome trace begin/end pair named `task:<operation>`
around `run_fn`, including error returns, but not around cleanup. Production
names are string literals, so their lifetime exceeds queued execution; a
dynamic name would need an owner with the same lifetime as the task context.

Each producer separately assigns one of four semantic priorities. Rendering
and direct user-input variants share the urgent rank, navigation/document work
uses the normal rank, and callbacks originating in `setTimeout`, `setInterval`,
XHR, or `postMessage` use the JavaScript-low rank. The trace name is diagnostic
only and never determines priority. Selection is FIFO within a rank. Ordinarily
the worker removes the oldest task at the greatest rank; after eight such
selections have bypassed lower-ranked entries, it removes exactly one oldest
lower-ranked entry and resets the burst. This bounded priority burst lets a due
animation frame jump a timeout backlog while guaranteeing eventual progress
for every finite older backlog. Queue clearing resets the burst state and still
cleans each discarded context exactly once.

Scheduling after shutdown immediately invokes cleanup. This is a useful local
contract. `TaskRunner.shutdown` publishes quit, cleans queued work, and joins
the active worker; after it returns, neither the runner nor an active task
context is borrowed by that worker.

### Detached helpers

`Browser.scheduleSetTimeoutTask`, `scheduleAnimationFrame`, and
`scheduleAsyncXhr` initiate detached OS threads; their thread contexts,
callbacks, and cleanup adapters live in
[`src/browser/script_tasks.zig`](../src/browser/script_tasks.zig). A Tab-level
mutex, condition, and reference count provide a logical join point: helper
teardown releases the reference as its final owner access, and `Tab.shutdown`
waits for zero before document destruction. Helpers that target a document
carry copied `DocumentHandle` values rather than `Frame` or `JsRenderContext`
pointers. Animation helpers borrow their heap-stable Tab under that helper
reference and pair it with the timer generation described below.

Animation timers wait for an absolute timestamp on the monotonic `awake` clock.
The first requested frame anchors a deadline one estimated interval in the
future; a continuous chain advances from the prior deadline rather than from
the preceding frame's completion. The estimator measures timer-delivered tab
work and the corresponding raster-worker/software-presentation pass as two
overlapping stages, smooths each independently, and uses the slower stage. It
rounds the required budget plus 3ms headroom up to a 33ms multiple, so an
overloaded page settles at 66ms, 99ms, or a slower bounded cadence rather than
repeatedly scheduling expired 33ms deadlines and pegging the CPU. Upward
half-delta smoothing reacts quickly; downward eighth-delta smoothing prevents
bucket oscillation and eventually restores 33ms when work becomes cheap.
Successful root navigation and active-tab changes reset samples so one page's
cost does not throttle another.

CSS transition state is owned by its DOM Element and advanced only by the
serialized Tab worker. The transition map is tagged by interpolation kind:
opacity stores a numeric interpolation, `background-color` stores RGBA
endpoints, width/height wrap numeric interpolation in a pixel-length variant,
and `transform` stores the two axes of a parsed `translate(...)`. Each entry
stores its timing function by value. Normalized frame progress is linear in
scheduler time, then `easing.zig` maps it through CSS `ease` by default or a
supported keyword/explicit cubic Bezier before property interpolation. Layout
reads current color and dimensions directly from the Element-owned map. Color
advances mark paint dirty; every width/height advance can serialize a stable
`px` value and marks the element's layout owner dirty so geometry and line
breaks are regenerated. Opacity and translation instead emit compositor updates; a
simultaneous pair for one element shares its numeric compositor ID and updates
one retained plane without paint or raster. A replacement style captures its
baseline from an active transition first, otherwise from
`ProtectedField.lastValue`: this intentionally means the last published visual
state even when a new style pass is pending, without treating the dirty field
as newly computed.

Named CSS animations retain a second Element-local cycle descriptor but reuse
the tagged property interpolation map. `@keyframes` names and declarations
borrow frame-owned stylesheet buffers only while rules are installed; starting
an animation parses supported `from`/`to` values into typed scalar/color/pixel/
translation endpoints, so playback owns no CSS text borrow. The descriptor
identifies its map entries, iteration count, and normal/alternate direction.
The Tab worker preserves terminal frames across cycle boundaries, reverses
alternate endpoints and their timing curves, and removes finite-animation
entries before restoring the underlying computed style. Property invalidation remains identical to
transitions, including compositor-only opacity/translation and layout-inducing
width/height.

When no follow-up frame is requested, or input/tab lifecycle forces a fresh
generation, the deadline anchor is cleared while the same-document cost
estimate remains useful. Detached timer helpers and their queued
`task:animation_frame` values carry the Browser's generation and may finish
only that generation. This lets reset paths supersede a helper without joining
it and prevents stale wakeups from clearing or enqueueing work for a newer
active tab. A timer-delivered commit carries the same generation and marks one
duration sample spanning worker raster/software draw plus the UI-thread SDL
upload; direct load/test commits deliberately do neither.
`setInterval` does not add a permanently looping helper. Its per-window
JavaScript registry retains the callback and requested delay; each live
delivery schedules exactly one new generation-stamped one-shot helper after
the callback returns. A second, mutex-protected Tab registry keys active
intervals by `(window_id, document_generation, handle)`. `clearInterval`
removes both entries; sleeping helpers observe the native removal within 10ms,
and already-queued deliveries find no JavaScript callback and become no-ops.
Document replacement and frame teardown clear that document's keys, while Tab
shutdown clears every key before joining helpers. One-shot timeout entries are
removed before their callback runs. Long timer helpers poll the tab shutdown
flag and exit promptly. Async HTTP still has no request cancellation, so
shutdown can safely wait but may wait for network I/O to finish.

### Current locks

- `Browser.lock` protects a subset of active-tab render state, dirty flags,
  shutdown/animation flags, and the independently owned optimistic-display and
  committed-document URL snapshots used by chrome. The committed snapshot's
  security state is published in the same commit: chrome emits a padlock only
  for a matching, verified HTTPS document, never for optimistic navigation
  text or a certificate-warning document. The active page's frame-time
  estimates and pending presentation-sample bit share this lock with its timer
  deadline/generation. Raster-job active/completed state crosses the worker/UI
  boundary under this lock; the worker holds it only to publish or reject a
  finished surface, never during z2d work.
- `TaskRunner.mutex` and its condition protect the task queue and worker flags.
- `BrowserSession.network_runner` serializes ordinary browser fetch dispatch.
  Linked-resource parallelism is represented as one queued task with joined
  child workers, so no child recursively waits on its coordinator's queue.
- `BrowserSession.network_lock` serializes shared cookie-jar and response-cache
  access across every window, plus synchronous `document.cookie` callbacks;
  it deliberately does not serialize the HTTP round trip. Requests own copied
  Cookie header values, cache hits own response copies, and callbacks retain no
  jar slice after releasing the lock.
- `BrowserSession.lock` protects owned session URL sets. Its visited generation
  is published atomically so render can detect stale link annotations without
  reading the map outside that lock. Chrome bookmark lookup holds
  `Browser.lock` only to stabilize the committed URL snapshot; bookmark
  toggling copies that text before taking the session lock. Address submission
  copies the optimistic display snapshot while it still owns the parsed URL,
  before transferring navigation ownership to a tab worker.
- BrowserApp samples both session generations without a session lock, then
  acquires at most one Browser lock at a time while publishing RAF or chrome
  work; it never holds a session and Browser lock together.
- `JsLock` is a recursive-by-thread-ID wrapper used around evaluation and many
  callback operations in [`src/script/js.zig`](../src/script/js.zig).

There is no general `Tab`/DOM/Layout/FontManager lock. A future contract should
prefer clear owner threads and immutable snapshots over extending one coarse
lock across parsing, layout, JavaScript, and rendering.

## Navigation contract

### Current root-frame sequence

`Browser.loadInTab` in [`src/browser/root.zig`](../src/browser/root.zig):

1. borrows the prior URL and copies its Frame's Referrer-Policy, then fetches or
   generates the document and decodes it while the URL owner and old document
   remain alive, so a failure preserves the old page;
2. records both the canonical requested and final redirect destinations after
   a successful fetch, then annotates parsed anchors using the same resolution
   policy as clicks;
3. clears queued old-generation tasks and invalidates JavaScript roots and host
   callbacks;
4. retires browser-side draw/layer/display snapshots under `Browser.lock`;
5. destroys the old root `Frame`, including layout, DOM, and source backing;
6. allocates and registers a new root `Frame`;
7. installs the response's Referrer-Policy before subresource discovery and
   transfers the decoded body to the frame as backing storage for the DOM;
8. stages stylesheet source buffers, parsed rules, and keyframes together;
9. assigns a unique document generation, parses scripts, builds layout/paint
   state, and commits browser-visible data;
10. applies any final-URL fragment to the completed layout and clamps the frame
   scroll range;
11. on an ordinary navigation, appends the prepared root action and its prior
   frame-tree snapshot; on replay, leaves the immutable action log alone while
   the new root Frame owns the cloned request URL. The traversal coordinator
   moves the shared index only after any nested snapshot restoration finishes.

`Tab.invalidateJsContext` in [`src/browser/tab.zig`](../src/browser/tab.zig)
zeros every current frame's document generation, clears its embedded
`JsRenderContext`, and calls `Js.setNodes(..., null)`. The old frame is
deinitialized only after this invalidation.

### Current child-frame sequence

Child-frame navigation reuses a `Frame` allocation.
`Browser.resetFrameForNavigation` first clears JS node roots and render-context
pointers, then retires provenance-bearing display state before destroying
children, layout, the old DOM, owned
rules and keyframes, stylesheet text, and finally decoded HTML and URL backing. The fetch
happens through the same owned `NavigationDocument` helper before reset so the
referrer and its copied policy remain valid, and browser-side render
state is retired under `Browser.lock` before reset frees document resources.
Installing the replacement assigns a fresh per-document generation. Initial
iframe loads and later navigation within an existing child frame check both the
requested and final redirect destinations against the parent document's CSP
before recording the visit or installing the child. Initial iframe discovery
is part of its containing document's state and does not append history. A later
child navigation prepares a path/request/prior-subtree action before reset and
commits it only after the new child document is ready; history replay uses the
same loader without appending another action. Script-created iframe Elements
start without a browsing-context marker and enter the initial child-frame
loader during their owning Frame's deferred resource refresh. Successful load
sets the Element's window ID only after the heap-stable Frame is registered and
inserted at its DOM-order child index. Script removal is the inverse: mutation
completion rebinds every surviving marker, moves those Frame pointers into
final DOM order, and deinitializes every unmatched context before another task
can resolve its document handle.

### Stylesheet generation transfer

Root and child navigation build `new_css_texts`, `all_rules`, and keyframes as
one staged generation. Error cleanup owns every staging collection until
success. Only after parsing and sorting succeed does the code replace
`frame.css_texts`, `frame.rules`, and `frame.keyframes`. Rules, keyframes, and
the source slices they borrow therefore cross the ownership boundary together.
Media-environment rebuilding also constructs a complete replacement generation
before retiring the old one; it runs on the serialized tab render path after
zoom, viewport width, color-scheme preference, or forced-colors changes. Root
media width is the native tab width divided by accessibility zoom. An iframe's
published viewport is in authored-zoom-scaled layout pixels, so media matching
divides it by the Frame's inherited authored factor. `max-width` compares
inclusively and `width` compares for equality with only enough tolerance to
erase f32 zoom round-trip noise. Every successfully replaced frame dirties its
complete computed-style subtree before style runs, so rules that became
inactive reset to the cascade beneath them. See `loadInTab`, `loadInFrame`,
`loadIframe`, and `rebuildFrameStyleRules`.

### Required navigation invariant

Before old document state is reclaimed, a complete navigation transaction must
guarantee:

1. no new task can be scheduled against the old document generation;
2. sleeping/network helpers are cancelled or retain only a copied stable
   document identity and owned request inputs;
3. queued tasks for the old generation are cleaned up;
4. an active tab task has reached a quiescent point;
5. JavaScript handles and host callbacks no longer expose old DOM pointers;
6. main-thread input/accessibility readers no longer expose old `Frame` or DOM
   pointers;
7. browser-side render snapshots that borrow old document resources are retired;
8. layout and invalidation subscriptions are detached;
9. DOM is destroyed before its source buffers, and URLs are released exactly
   once.

The current code enforces task cleanup, copied document handles, callback/root
invalidation, render-snapshot retirement, and source/URL teardown order. Main
thread readers, address-stable DOM identity, and invalidation unsubscription
still prevent this from being a complete atomic transaction.

## Render and commit contract

The tab worker styles, lays out, and paints one authoritative uncomposed list
per frame. It retains those lists for synchronous hit testing instead of moving
the root list into a commit. `Tab.composeDisplayList` recursively copies the
root and child-frame lists, replaces iframe placeholders with translated and
clipped child content, owns every copied child slice/blend-mode string, and
clears `DisplayItemSource` throughout the result. `Browser.commit` receives
that separate list under `Browser.lock`, recursively clones its owning
containers once more, frees the incoming composition, and installs the clone
as `active_tab_display_list`; see `composeDisplayList`, `cloneDisplayItem`,
`cloneDisplayItemList`, and `commit` in [`src/browser/tab.zig`](../src/browser/tab.zig)
and [`src/browser/root.zig`](../src/browser/root.zig).

The composition/clone boundary separates container ownership and prevents the
browser snapshot from retaining layout/DOM hit-test provenance. It still
borrows image bytes, glyph resources, composited layers, and the existing
effect-node identities, so it is not an independent resource snapshot.
Changing a computed CSS background therefore retires this browser-side state
before freeing the old Element-owned pixels, then commits the replacement
generation normally.
Selecting a clean tab publishes an atomic activation request to its serialized
worker. That worker composes the retained lists and commits the frame's scroll
and current URL even when no style/layout/paint dirty flag is set, avoiding a
blank render or empty chrome URL after switching tabs.

The unresolved render contract must choose one of these models:

- make snapshots self-contained by copying or reference-counting every leaf
  resource and replacing raw DOM pointers with stable IDs; or
- retain the complete document/resource generation until every browser-side
  snapshot and composited layer for it has been retired.

Whichever model is chosen, `commit` must be the sole ownership handoff and the
main thread must never observe a partially built snapshot.

## JavaScript and Kiesel contract

Each `Tab` keeps a `Js` instance per origin. Each instance contains a map of
window IDs to `WindowContext`; every window stores the current DOM root, raw
`*Node` to integer handle maps, pending messages, and host callbacks. See
`WindowContext` in [`src/script/js.zig`](../src/script/js.zig) and `Tab.getJs`
in [`src/browser/tab.zig`](../src/browser/tab.zig).

Current enforced behavior includes:

- the scanned, uncollectable `Js` allocation roots the embedded Kiesel `Agent`;
- entry into evaluation and callback execution is serialized by `JsLock`;
- node listener maps are window-scoped. Dispatch snapshots target and ancestor
  handles before invoking the first listener, then reuses one Event with a
  fixed `target` and per-node `currentTarget`; `stopPropagation` stops before
  the next ancestor but does not skip remaining listeners on the current node;
- every tab-owned `Js` installs a Kiesel host-interrupt callback that reads the
  tab's atomic shutdown flag; the VM polls it at bytecode safe points and turns
  it into an uncatchable host error at the `Js.evaluate` boundary;
- `Js.setNodes` changes the root, clears both handle maps, and resets callbacks
  when the root becomes null. Null-root invalidation can run during main-thread
  teardown, so it does not re-enter Kiesel; retained numeric wrappers become
  inert immediately, and a later non-null install clears/rebuilds the registry
  on the tab worker before evaluation;
- each `WindowContext` has a JavaScript-side registry of named element globals;
  only the active window's first element for each non-empty ID is installed,
  pre-existing global names win, and realm activation swaps registries without
  exposing another window's nodes;
- `Node.id` reflects `getAttribute`/`setAttribute`. `innerHTML` reads serialize
  current children, `outerHTML` includes the element, and the returned source
  buffer is allocated in Kiesel's traced heap because its ASCII string cache
  may retain the supplied bytes instead of copying them;
- the `Node.children` getter snapshots immediate element-child handles in DOM
  order and wraps them as JavaScript Nodes; text children and deeper
  descendants are excluded, and every getter call creates a new array;
- `document.createElement` owns a lowercase-tagged detached element in its
  `WindowContext`; `Node.appendChild` and `Node.insertBefore` transfer only a
  detached root, preserve its handle, and rebind handles for immediate siblings
  relocated by the insertion;
- `Node.removeChild` accepts only a direct child, moves its complete subtree to
  a heap-stable `WindowContext` owner, preserves its handles, rebinds shifted
  sibling handles, and returns the same root eligible for either insertion
  method;
- `innerHTML` calls `removeHandlesForSubtree` for every removed child before
  destroying it, so descendant JavaScript handles are removed with the old
  subtree;
- attached `innerHTML`, `appendChild`, `insertBefore`, `removeChild`, and `id`
  attribute changes clear named globals before mutation and republish them
  afterward. Detached elements remain absent until insertion, and detached
  subtrees disappear immediately while retaining handles for reattachment;
- structural `innerHTML` invokes its dedicated synchronous DOM-mutation host
  callback before old child storage retires; ordinary render callbacks remain
  a separate, non-destructive invalidation path. A distinct completion callback
  runs after the final child storage and handle repair, allowing iframe Frame
  bindings to be reconciled without retaining the old Node address or starting
  network work inside Kiesel;
- `JsRenderContext` connects a frame window to Browser/Tab/Js host pointers and
  carries a generation number while it is synchronously registered with
  Kiesel;
- pending scripts, child-frame navigations, timers, XHR completions, and
  `postMessage` tasks carry a copied `(window_id, document_generation)` handle
  and resolve it only on the serialized tab worker.
- `postMessage` additionally owns a parsed target-origin policy. `*` permits
  every target, `/` snapshots the sender's origin, and absolute URL values are
  reduced to scheme, host, and effective port by URL same-origin comparison.
  The task evaluates that policy only after resolving the target document at
  delivery time; stale generations and mismatched origins dispatch no event.
  The source origin is serialized at send time, and event data/origin move to
  Kiesel-owned storage before the queued payload is freed. Cross-origin child
  realms retain only their parent's numeric window identity, which backs a
  postMessage-only JavaScript proxy without installing the parent's DOM realm.

Unresolved parts of the contract are:

- DOM identity is still based on raw addresses of nodes stored in resizable
  arrays outside the repaired `innerHTML` path;
- callback setter methods and `setParentWindow` mutate window/map state without
  acquiring `JsLock`;
- no enforced owner-thread rule explains when those unlocked methods are safe.

The raw `JsRenderContext` callback pointer remains a synchronous borrow cleared
by `Js.setNodes(..., null)` before frame destruction. Asynchronous paths must
continue to use `DocumentHandle`. DOM handles still need a generation or a
stable-node representation so reuse of an array address cannot silently
retarget an old JavaScript wrapper.

## Accessibility contract

F6 changes the active Tab's forced-colors mode and schedules a complete media,
style, layout, and paint refresh. The same setting is supplied to every frame's
`(forced-colors: active)` query. During paint, layout classifies author CSS
colors by semantic role and `render/forced_colors.zig` replaces their RGB
channels with black canvas/control backgrounds, white text/borders, cyan links,
or yellow visited/accent paint while retaining nonzero author alpha.
The root document always emits a black canvas in this mode. Raster snapshots
therefore contain only the small system palette for CSS paint; decoded content
images and color glyph bitmaps remain unmodified, while decorative CSS
background images are omitted.

Focused page elements retain both `Element.is_focused` and a focus-visible bit
chosen from the Tab's current input modality. Primary clicks record pointer
modality before JavaScript dispatch; links and buttons receive focus without a
ring, while visible inputs and contenteditable controls keep one. Keyboard
editing, activation, scrolling, or traversal promotes the current focus and
all subsequently focused controls to focus-visible. Synchronous `focus()`
inherits that modality. Blur and DOM-retirement boundaries clear both bits,
and every transition dirties style so `:focus-visible` rematches in the same
generation consumed by native paint.

When that focus-visible bit is set, page paint appends the indicator after
document content using the layout generation's focus bounds.
`render/focus_ring.zig` reserves and emits a 4px white outline followed by a
coincident 2px black outline around the padded bounds. The black center remains
visible on light content and the exposed white edge remains visible on dark
content. Both commands are pointer-free and move with the frame display-list
generation; the amber accessibility highlight is a separate single outline
and does not replace either focus stroke. Layout still records every
programmatically focusable target because JavaScript focus needs geometry even
when pointer modality suppresses the eventual ring.

Inline focus geometry is collected from painted fragments, not merely from the
DOM node that directly owns each glyph. Every fragment climbs to its nearest
focusable ancestor, so nested inline descendants are unioned into one bounds
entry per visual line and wrapped inlines retain multiple rectangles. Once a
focusable block has laid out its descendants, it transactionally replaces all
of its own fragment entries with the block box while leaving independently
focusable descendant entries intact. This prevents multiline block targets
from acquiring a separate ring around every line.

`Tab.buildAccessibilityTree` in
[`src/browser/tab.zig`](../src/browser/tab.zig) now moves the prior generation's
string list to `previous_strings`. The previous tree and strings remain alive
through `handleLiveRegionUpdates`; a deferred cleanup releases both afterward.
The new tree uses a new `accessibility_strings` generation.

This fixes the prior name-slice lifetime violation. It does not establish a
cross-thread snapshot: main-thread hover and voice paths can still read or
mutate accessibility state while the tab worker rebuilds it. That broader
thread-ownership contract remains unresolved.

Document reading is incremental: `Tab.advanceAccessibility` walks one preorder
accessibility node per F4/read-page request, queues that node's speech, and
stores it as the amber highlight target so the next paint displays exactly
what was announced. Queueing synchronously flattens reason, role, name, and any
non-password input value into independently owned bytes. The per-Tab
`Accessibility thread` therefore blocks only itself inside the speech backend
and its queued payload never retains a Tab, DOM node, accessibility node, or
tree-string slice. The thread itself borrows its heap-stable Tab's embedded
runner field until `shutdown` joins it.
Requests are serialized in queue order. Disabling the screen reader clears
requests that have not begun; an active call remains owned until shutdown joins
it. The synthetic document root is not the first visual target. Because
accessibility trees are rebuilt after layout, the reading and highlight
pointers are remapped through their borrowed DOM nodes while the replacement
tree is alive; if a node was removed, the cursor is cleared.

## SDL and graphics contract

`BrowserApp.init` initializes SDL video, holds one process-level SDL_ttf
reference, and starts text input before creating any window. Every
`Browser.initAppWindow` then creates its page and chrome `Layout`/`FontManager`
pairs, native window, accelerated renderer, presentation texture, and z2d
surfaces while borrowing those process services. SDL_ttf documents
`TTF_Init`/`TTF_Quit` as a reference count: each FontManager retains its
existing pair, while the App
guard prevents closing one window from taking the library to zero beneath
another. Direct `Browser.init` remains the standalone path and initializes its
own SDL/session/measurement resources. Screenshot mode creates no native
window, renderer, presentation texture, or text-input owner; it waits until the
tab worker and all accounted helpers are quiescent, renders to z2d, and exports
`root_surface` directly. See [`src/browser/app.zig`](../src/browser/app.zig) and
[`src/browser/root.zig`](../src/browser/root.zig).
`FontManager` does not retain the renderer. `getStyledGlyph` mutates SDL_ttf
font state, renders a temporary SDL surface, converts it to canonical RGBA,
and stores only allocator-owned bytes; see
[`src/browser/render/font.zig`](../src/browser/render/font.zig).

Each Browser's page `Layout` and `FontManager` are reachable from that window's
tab layout/paint work and some main-thread page-input paths. Chrome uses a
second main-thread-only pair. The raster worker never enters either layout or
font manager: its UI-created snapshot copies canonical glyph RGBA and image
bytes while `Browser.lock` prevents source-generation retirement. Screenshot
mode still waits for the serialized tab worker and all accounted helpers before
snapshotting so captures are deterministic. The renderer never participates in
glyph-cache mutation.

Each worker builds a complete root z2d surface, including the bounded page
interest region, isolated blend/filter/mask groups, chrome commands, and the
scrollbar. A one-child `dst_in` remains a list-level mask within its enclosing
isolated group; other `needs_compositing` boundaries receive independent
temporary surfaces, so a clip cannot consume unrelated earlier pixels. The
completed surface transfers to the UI thread as a single owner. Only that
thread replaces `Browser.root_surface`, locks/copies the streaming SDL texture,
copies it to the renderer, and calls `present`. The row-wise texture copy keeps
this unavoidable SDL section short.

Normal `Browser.deinit` publishes shutdown and joins its raster worker first,
then quiesces its tabs and retires display snapshots,
destroys document state, frees cached glyph bitmaps and closes fonts, tears
down z2d state, then destroys that window's texture, renderer, and native
handle. An App-owned Browser leaves shared session, measurement, text input,
and SDL untouched. After all entries are gone, BrowserApp stops and joins the
networking runner, destroys the shared HTTP/cookie/cache/session state, finishes
measurement once, stops text input, releases
its final SDL_ttf guard, and quits SDL. Standalone Browser owns those same final
steps itself. Both constructors use reverse-order `errdefer` rollback.

The enforced SDL contract is:

1. the Browser/UI thread exclusively owns the SDL renderer and all
   renderer-bound textures; raster workers perform software-only z2d work;
2. separately serialize mutable SDL_ttf font and glyph-cache access;
3. stop workers before freeing glyph bitmaps or destroying fonts, surfaces,
   renderer, or window;
4. destroy resources in reverse dependency order;
5. make every partial initialization path use the same ownership order.

## Shutdown contract

`Browser.deinit`, `Tab.shutdown`, and BrowserApp teardown enforce these phases:

1. publish shutdown and reject new browser/tab/JS work;
2. stop/join each Browser's raster runner and release any completed surface;
3. wake long timer helpers, interrupt JavaScript running on each tab worker,
   stop/join those serialized workers, then cancel/join each Tab's
   accessibility runner after its final speech producer is gone;
4. wait for accounted helpers, whose completion tasks are rejected and cleaned
   by the stopped runner;
5. retire browser render snapshots, then destroy tabs, frames, DOM, and JS;
6. destroy each Browser's layout, font, z2d, renderer, and window resources;
7. after the final Browser is gone, stop/join the networking runner, destroy
   shared HTTP/cookie/cache/session state, and finish measurement once, when no
   thread can record into either;
8. stop text input, release the App's SDL_ttf guard, and quit SDL.

Async HTTP requests are not cancellable yet, so phase 3 can block on network
I/O; it remains memory-safe because BrowserSession, Tab, Browser, and
measurement owners stay alive through the wait.

## Resolved lifetime repairs

These former risks are now resolved in the current code and should not be
reintroduced:

1. **Worker quiescence:** `TaskRunner.shutdown` rejects new tasks, cleans queued
   contexts exactly once, and joins the active worker before runner storage can
   be destroyed. A focused test holds an active task while shutdown begins and
   verifies the join and cleanup boundary. See
   [`src/runtime/task.zig`](../src/runtime/task.zig).
2. **Queued and async document identity:** detached timeout/XHR helpers,
   child-frame navigation, and queued completions no longer retain a Frame
   pointer across a scheduling boundary. They carry a copied `DocumentHandle`,
   and work resolves only if the same window and document generation still
   exist on the tab worker. `postMessage` captures the target document
   generation. See
   [`src/browser/root.zig`](../src/browser/root.zig).
3. **Navigation backing order:** root navigation and child reset invalidate JS
   callbacks, destroy layout before DOM, destroy DOM before CSS/HTML backing,
   and keep the old URL owner alive through referrer use. See `loadInTab`,
   `loadInFrame`, `resetFrameForNavigation`, and `Tab.invalidateJsContext`.
4. **Committed render retirement:** draw-list layer pointers, composited layers,
   and the active display list retire in dependency order under `Browser.lock`
   before document navigation, tab destruction, or display-list replacement.
   See `retireActiveRenderStateLocked` and `retireRenderStateForTab`.
5. **URL snapshots:** `Url.clone` creates independent Ada and data-URL storage;
   async XHR clones target/referrer inputs before spawning. Clone behavior is
   covered with normal, data, and `view-source:` URLs.
6. **Shutdown owner order:** Each Browser publishes shutdown, joins tab
   workers, waits helpers, retires render snapshots, then destroys its tabs,
   fonts, z2d, renderer, and window. BrowserApp destroys shared network/session
   and measurement state only after the final window, then releases process SDL
   state. Long timers poll cancellation and Kiesel polls a host interrupt at VM
   safe points, so neither a distant timeout nor an infinite page script can
   indefinitely prevent the worker join. See
   [`tests/manual/lifecycle-long-timeout.html`](../tests/manual/lifecycle-long-timeout.html).
7. **Stylesheet generation ownership:** root and child stylesheet source
   buffers and parsed rules are staged, cleaned up on error, and moved into
   `Frame` together. Rule rebuilding also preserves the prior generation until
   its replacement is complete. See the `new_css_texts`/`all_rules`
   transactions and `rebuildFrameStyleRules`.
8. **Accessibility diff backing:** the previous accessibility strings stay
   alive through the old/new tree diff. See `previous_strings` in
   `Tab.buildAccessibilityTree`.
9. **Subtree JS handles:** `innerHTML` recursively removes handles for
   descendants before destroying the old subtree. See
   `removeHandlesForSubtree` in [`src/script/js.zig`](../src/script/js.zig).
10. **`view-source:` Ada ownership:** `Url.init` replaces the wrapper Ada URL
   with the inner URL and `Url.free` releases that same owner. See
   [`src/network/url.zig`](../src/network/url.zig).
11. **Glyph metadata:** cached `Glyph` values no longer retain a borrowed
   grapheme slice. See [`src/browser/render/font.zig`](../src/browser/render/font.zig).
12. **Platform initialization rollback:** `BrowserApp.init`, `Browser.init`,
   `Browser.initAppWindow`, and `Layout.init` unwind previously created
   native/allocator resources in reverse dependency order; font discovery and
   font insertion also clean partial allocations. Every Browser is allocated at
   its final address before binding z2d `Context` to its root surface, avoiding
   a self-pointer into an init-local copy.
13. **JS context construction rollback:** origin keys and newly constructed
   Kiesel host contexts remain locally owned until insertion into the tab map,
   so allocation or map-insertion failure cannot strand either owner.
14. **Structural DOM snapshot retirement:** `innerHTML`, detached-root
   `appendChild`/`insertBefore`, `removeChild`, and the native first
   contenteditable child append mark layout/render work and synchronously
   retire frame/browser DOM-derived snapshots before a child can move or be
   destroyed. Browser-side image/effect borrows retire under `Browser.lock`;
   focus on a surviving mutation root is preserved, while removed-descendant
   focus and accessibility/hit indexes are cleared. JavaScript insertion
   additionally rebinds handles for immediate siblings shifted or relocated by
   the child array; removal also rebinds the detached root and clears its
   obsolete layout pointers. See `prepareDomMutation`,
   `Tab.prepareForDomMutation`, and
   `Frame.retireDomMutationBorrows`.
15. **Script-mutated iframe ownership:** iframe Elements retain only a numeric
   child-window marker across Node-array relocation. The synchronous mutation
   completion pass validates that marker against the Tab registry, repairs
   surviving Frame element pointers/order, and recursively deinitializes
   removed contexts before JavaScript resumes. The deferred resource scan loads
   marker-free additions through the normal iframe navigation pipeline, so no
   network call re-enters the active host mutation. See
   `Element.iframe_window_id`, `Frame.reconcileAttachedChildFrames`, and
   `Browser.loadIframes`.

## Confirmed unresolved lifetime risks

A confirmed issue means the structural ownership gap is visible in code. It
does not mean every run will manifest a crash.

### 1. DOM identity remains address-unstable

Children live by value in resizable arrays while layout, hit-test, focus,
frame-element, accessibility, display, and JS structures store `*Node`.
The supported `innerHTML` and first contenteditable append paths now retire
their DOM-derived browser state synchronously, and `innerHTML` clears handles
for the subtree it removes. The supported detached-root insertion and removal
paths also rebind immediate-child JavaScript handles after relocation. These
boundaries do not create stable identity for future mutation APIs or every
retained JS/frame borrower. See
[`src/document/parser.zig`](../src/document/parser.zig),
[`src/script/js.zig`](../src/script/js.zig), and
[`src/browser/tab.zig`](../src/browser/tab.zig).

### 2. ProtectedField dependencies cannot unsubscribe

Dependency sources retain raw pointers to dependent fields. Dependent teardown
does not remove those entries from the source, while style/layout rebuilding
can destroy dependents before their sources. The missing reverse edge or
subscription token is visible in
[`src/core/protected_field.zig`](../src/core/protected_field.zig).
Supported structural DOM paths now clear all style-source subscriber maps
before mutation and force a full rebuild; arbitrary or incremental teardown
still lacks an edge-specific lifetime mechanism.

### 3. Display-list cloning does not make leaf resources independent

The browser clone recursively owns only container slices and blend-mode text;
primitive variants are copied by value. Those primitives contain borrowed
image, glyph, DOM, and layer resources. See `cloneDisplayItem` in
[`src/browser/root.zig`](../src/browser/root.zig).

Snapshot retirement now closes navigation, replacement, shutdown, and the
supported in-place structural-mutation paths. The clone is still not
independently safe by type; every future mutation path must enter the same
synchronous retirement boundary before retiring a leaf.

### 4. Interactive Layout and FontManager access has no global contract

Each Browser owns a mutable page layout/font stack, and Chrome owns a separate
UI-thread-only stack. This removes chrome rasterization from the page stack,
but interactive resize and page-input paths still reach page layout state from
the main thread while that window's tab tasks use it for document layout and
glyph creation. No common owner-thread assertion or lock covers those remaining
interactive paths. Windowless screenshot capture is excluded from this gap by
its tab/helper quiescence gate, but the interactive concurrency gap remains.

### 5. Response and URL ownership is encoded in call-site convention

Response-body ownership is inferred from schemes, while `Url` remains an owning
value whose plain assignment is shallow. `Url.clone` provides the required
operation, but the type system still cannot prevent accidental copy, leak,
double free, or a wrongly freed borrowed response when a caller/scheme is added.

### 6. JavaScript host mutation has a partial lock contract

Evaluation and many callback entry points use `JsLock`, but callback setter
methods and `setParentWindow` do not. This may be valid under an owner-thread
rule, but no such rule is asserted or documented in the API. See
[`src/script/js.zig`](../src/script/js.zig).

### 7. Async HTTP has no cancellation path

The XHR helper owns its request inputs and stays accounted until it destroys
them, so Browser/Tab/HTTP storage remains valid. A blocked network operation can
still delay shutdown indefinitely because there is no cancellation token or
request deadline.

### 8. Main-thread readers lack a complete document snapshot contract

Input, accessibility, and some render/chrome paths can read tab/frame state
while the worker mutates it. `Browser.lock` protects committed render state but
does not cover the DOM/accessibility/layout graph. This remains a race and
ownership gap independent of the repaired navigation teardown.

## Hypotheses requiring focused tests

These consequences are plausible from the confirmed structure, but should not
be presented as root causes without a reproducer, sanitizer evidence, or a
targeted stress test:

- a browser display list reading image bytes or DOM identity after the tab
  worker mutates a subtree before publishing the replacement commit;
- `ProtectedField.notify` reaching a destroyed child style/layout field after a
  mutation or rebuild outside the supported structural clear-and-rebuild seam;
- main-thread accessibility hit testing racing a worker rebuild and observing
  a retired tree, despite the repaired string-generation ownership;
- simultaneous main-thread and tab-thread font/cache mutation corrupting
  SDL_ttf or hash-map state;
- an arena-backed build appearing stable while a reclaiming test allocator
  reuses freed storage and exposes a latent UAF;

Focused tests should force timing rather than rely only on random site loading.
The long-timeout shutdown fixture now covers timer cancellation. Still needed:
navigate while XHR is outstanding, mutate subtrees after exporting JS handles,
repeatedly rebuild layouts, force Kiesel GC, render image-heavy pages during
mutation, and close the browser during each phase.

## Contracts to establish during cleanup

1. **Thread owner:** name the sole mutation thread for Browser render state,
   each Tab/DOM, Layout/FontManager, and SDL renderer objects.
2. **Join and cancellation:** extend the established TaskRunner/helper
   quiescence boundary with async HTTP cancellation/deadlines.
3. **DOM identity:** choose stable individual node allocations or stable
   `(document_generation, node_id)` handles; do not expose array element
   addresses as persistent identity.
4. **Navigation:** make document replacement a quiescent transaction following
   the invariant listed above.
5. **Invalidation graph:** return subscription handles or maintain reverse edges
   so destruction always unsubscribes.
6. **Render snapshot:** either own/reference-count every leaf resource or retain
   the producing document generation until retirement.
7. **JS host lifetime:** root Kiesel data deliberately, lock every cross-thread
   host operation, and use stable IDs/tokens for callbacks.
8. **Network types:** encode owned versus borrowed bodies in a tagged type with
   one `deinit`; expose explicit `Url.clone`, borrow, and move operations.
9. **SDL lifecycle:** enforce renderer thread affinity and reverse-order,
   error-safe destruction of textures, fonts, renderer, window, and SDL.
10. **Allocator verification:** run ownership tests with a reclaiming allocator
    and leak detection; production arena success is not sufficient evidence.

## Forbidden patterns

Until stronger types enforce these contracts, new code should not:

- detach a thread that retains owner pointers without an accounting reference,
  cancellation path, and shutdown wait that outlive it;
- use a generation field embedded in an object that asynchronous work can
  outlive;
- free or replace a source buffer while DOM, CSS, layout, or display data still
  contains slices into it;
- store `*Node` across an operation that may append, remove, clear, sort, or
  replace a node's sibling array;
- mutate a DOM subtree without invalidating JS handles, focus/hit-test maps,
  accessibility pointers, layout back-pointers, and render snapshots;
- shallow-copy an owning `Url`, response, texture, image, surface, or display
  container and let both copies appear owning;
- return or move a value after storing pointers to its own fields unless the
  pointees have an independently stable allocation;
- represent ownership only with a boolean at distant call sites when a tagged
  owner/borrower type or RAII wrapper can express it;
- register a raw callback dependency without a corresponding unregister path;
- retain a borrowed string or pixel slice without naming and retaining its
  owner;
- call renderer-bound SDL APIs from an arbitrary worker thread;
- destroy a Browser before joining its tasks/helpers, or destroy BrowserApp
  session/measurement/SDL services before every Browser has retired;
- assume a short sleep, idle poll, generation mismatch, arena allocation, or
  process exit makes a lifetime safe;
- add a lock to one field and infer that the entire object graph is protected.

## Lifetime review checklist

- [ ] Every allocation and native handle has exactly one named owner.
- [ ] Every borrowed slice/pointer names the owner and the event that ends the
      borrow.
- [ ] Owning values are moved or cloned explicitly; no accidental shallow copy
      can lead to two releases.
- [ ] A structural DOM mutation preserves stable identity or invalidates every
      exported pointer, handle, and index in the same transaction.
- [ ] Source buffers outlive all parsed slices.
- [ ] Stylesheet rules and their backing text move and retire as one generation.
- [ ] Layout and invalidation subscriptions are removed before either endpoint
      is destroyed.
- [ ] Async work owns its arguments or borrows only stable, retained state.
- [ ] Cancellation tokens outlive the work that reads them.
- [ ] Threads are joined before owners, allocators, locks, queues, and
      measurement state are destroyed.
- [ ] Cross-thread operations have an asserted owner thread, immutable snapshot,
      or clearly scoped lock.
- [ ] Render snapshots remain valid independently of subsequent navigation, or
      explicitly retain the producing document generation.
- [ ] JS node handles cannot resolve to a different node after mutation.
- [ ] Kiesel objects reachable from host state have an intentional GC root.
- [ ] Response and URL ownership is explicit at each function boundary.
- [ ] SDL/SDL_ttf resources are created and destroyed on permitted threads in
      reverse dependency order.
- [ ] Partial initialization has complete `errdefer` rollback.
- [ ] The change is exercised with a reclaiming/leak-detecting allocator where
      practical.
- [ ] Tests cover navigation or shutdown while relevant async work is active.

## Recommended cleanup order

The worker join, document handles, navigation snapshot retirement, timer
cancellation, and normal shutdown order are now foundations rather than open
steps. Continue in this order:

1. define and assert owner threads for DOM, Layout/FontManager, and SDL work;
2. introduce stable DOM identity and centralized mutation invalidation;
3. make render snapshots self-contained or generation-retained across in-place
   DOM mutation;
4. add invalidation unsubscribe semantics;
5. tag response ownership, add XHR cancellation/deadlines, and audit
   dependency-local initialization rollback;
6. add stress tests and debug assertions for each contract.

Update this document whenever an unresolved contract is decided. Once a
contract is enforced by types, ownership wrappers, joins, or assertions, move
it from the risk registry to the resolved section and record the enforcement
point.

## Inspection pipeline boundaries

The command-line inspection modes are deliberately narrower than an
interactive browser run. `--dump-dom` fetches, decodes, and parses only.
`--dump-style` additionally collects linked stylesheets and applies the
cascade. `--dump-layout` initializes SDL_ttf font measurement without a
window or renderer, then builds geometry while skipping interactive hit-test
state. `--dump-display-list` extends that path through paint-command creation,
but never enters compositing or rasterization. `--screenshot` continues through
software composition and rasterization without an SDL window, renderer,
presentation texture, or event polling, then writes the z2d root surface as a
PNG. Keep these boundaries intact so each mode can isolate a failure to one
stage of the browser pipeline.
