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
| [`src/main.zig`](../src/main.zig) | Executable entry point, CLI parsing, process arena, isolated DOM/style/layout/display-list dumps, Browser construction, and screenshot mode. |
| [`src/browser/root.zig`](../src/browser/root.zig) | Process-wide `Browser`, SDL event loop, navigation orchestration, fetch coordination, async host helpers, render commit, composition, raster, and draw. |
| [`src/browser/tab.zig`](../src/browser/tab.zig) | `Tab` and `Frame` ownership, task serialization, history, frame lookup, accessibility, focus, and per-document state. |
| [`src/browser/chrome.zig`](../src/browser/chrome.zig) | Browser chrome UI and its display data. |
| [`src/browser/render/layout.zig`](../src/browser/render/layout.zig) | Layout tree, invalidation dependencies, hit-test collection, paint, and image layout. |
| [`src/browser/render/font.zig`](../src/browser/render/font.zig) | Font discovery, SDL_ttf handles, glyph textures, and software glyph pixels. |
| [`src/document/parser.zig`](../src/document/parser.zig) | HTML parser, DOM representation, style maps, images, and DOM tree utilities. |
| [`src/document/inspection.zig`](../src/document/inspection.zig) | Browser-free fetch/decode/parse/style pipeline for document inspection commands. |
| [`src/document/css_parser.zig`](../src/document/css_parser.zig) | CSS parsing and `CSSRule` ownership. |
| [`src/document/selector.zig`](../src/document/selector.zig) | Selector representation and matching. |
| [`src/network/url.zig`](../src/network/url.zig) | Owning `Url`, URL resolution, schemes, HTTP requests, redirects, cookies, and response bodies. |
| [`src/script/js.zig`](../src/script/js.zig) | Kiesel host integration, realms/windows, DOM handles, JavaScript evaluation, events, timers, XHR, and host callbacks. |
| [`src/runtime/task.zig`](../src/runtime/task.zig) | Per-tab serialized task worker and opaque task-context cleanup. |
| [`src/runtime/sync.zig`](../src/runtime/sync.zig) | Runtime synchronization wrappers. |
| [`src/runtime/measure_time.zig`](../src/runtime/measure_time.zig) | Cross-thread measurement and profiling state. |
| [`src/core/protected_field.zig`](../src/core/protected_field.zig) | Reactive dirty/invalidation fields used by style and layout. |
| [`src/tests/`](../src/tests) and [`src/test_root.zig`](../src/test_root.zig) | Zig tests. |

## Runtime topology

The runtime currently has three kinds of execution context:

```text
process main thread
  Browser
    SDL event loop
    chrome, composite, raster, draw
    committed Browser render snapshot
    shared Layout / FontManager / SDL renderer
          |
          | schedules Task values
          v
  one TaskRunner worker per Tab
    navigation, parsing, DOM, style, layout, paint, JavaScript host work
          |
          | spawns accounted helper threads
          v
    setTimeout thread(s), animation timer thread, async XHR thread(s)
          |
          `---- enqueue completion Task values back onto the Tab worker
```

The entry point uses `init.arena.allocator()` and constructs one process-wide
heap-stable `Browser`; see `zibra` in [`src/main.zig`](../src/main.zig).
Heap stability is required because z2d `Context` stores a pointer to
`Browser.root_surface`. `Browser` owns the platform and cross-tab state. Each
`Tab` owns one `TaskRunner`. `Tab.start` must run only after the `Tab` reaches
its final address because the worker retains a pointer to the tab-owned runner;
see `Tab.start` in [`src/browser/tab.zig`](../src/browser/tab.zig).

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
| SDL and SDL_ttf | Window, renderer, textures, surfaces, fonts, and SDL_ttf handles are native resources. `FontManager.deinit` destroys glyph textures, frees pixel masks, closes fonts, and quits SDL_ttf; see [`src/browser/render/font.zig`](../src/browser/render/font.zig). | Native handles require deterministic release and an explicit thread-affinity rule. |
| z2d and zigimg | `Browser` owns long-lived z2d surfaces/contexts. `ImageData` owns a `zigimg.Image` and, when present, its encoded byte buffer; see [`src/document/parser.zig`](../src/document/parser.zig). | Layout and display items borrow pixel slices from these owners. The source image must outlive every borrower. |

## Ownership topology

### Browser

`Browser` in [`src/browser/root.zig`](../src/browser/root.zig) owns:

- the SDL window, renderer, cached output texture, and text-input lifecycle;
- root, chrome, and optional tab z2d surfaces plus the root z2d context;
- the shared `std.http.Client` and cookie jar;
- the shared `Layout`, including its `FontManager`;
- default user-agent CSS rules;
- all `Tab` allocations;
- the active browser-side display-list snapshot, composited layers, and tab draw
  list;
- browser chrome, measurement/profiling state, and browser render flags.

`Tab.browser` is a borrowed back-pointer. Task and helper contexts also borrow
`Browser`; `Browser.deinit` therefore publishes shutdown, joins every tab
worker, waits for every accounted helper, and only then destroys shared state.

### Tab

`Tab` in [`src/browser/tab.zig`](../src/browser/tab.zig) owns:

- URL history entries;
- one root `Frame`, which recursively owns child frames;
- one Kiesel `Js` context per origin key;
- frame-ID maps plus tab-wide and per-document generation counters;
- the `TaskRunner` and accounting for detached helper threads;
- dynamic text allocations;
- the accessibility tree and its backing strings;
- per-tab dirty flags and composited updates.

`Tab` borrows its `Browser` and the browser-owned `MeasureTime` used by its
`TaskRunner`.

### Frame

`Frame` in [`src/browser/tab.zig`](../src/browser/tab.zig) owns:

- child `Frame` allocations;
- the document's decoded HTML source;
- the root DOM `Node` value;
- document layout and the frame-side display list;
- owned CSS rules and the stylesheet source buffers borrowed by those rules;
- hit-test collections and allowed-origin strings;
- a frame-owned URL only when `current_url_owned` is true.

The root frame normally borrows its URL from `Tab.history`; child frames may
own their URL. `parent`, `tab`, `frame_element`, focus pointers, hit-test node
pointers, `js_context`, and layout-related node pointers are borrowed.

`Frame.deinit` destroys display/layout state before DOM and destroys DOM before
the decoded HTML source. That order is required because layout borrows DOM and
DOM strings borrow the HTML source.

### DOM and source buffers

Elements store children by value in `ArrayList(Node)` and store raw parent and
layout pointers; see `Element` and `Node.appendChild` in
[`src/document/parser.zig`](../src/document/parser.zig). Parser-created tag,
text, attribute, and CSS value slices generally borrow their input buffer.
Therefore:

1. the decoded HTML source must outlive the complete DOM;
2. a stylesheet source must outlive all rule property names and values parsed
   from it;
3. an address of an `ArrayList(Node)` element is valid only until a structural
   mutation can relocate or remove that element;
4. all DOM-derived indexes and handles must be invalidated or updated in the
   same transaction as structural mutation.

The parser acknowledges child-array relocation by fixing parent pointers after
tree construction rather than during `appendChild`. That repair only updates
parent pointers; it does not repair every other retained `*Node`.

### CSS rules and invalidation fields

`CSSRule` owns selector allocations and property-map storage, while property
keys and values are slices into the parser's source string. See `CSSParser.word`,
`CSSParser.value`, `CSSParser.body`, and `CSSRule.deinit` in
[`src/document/css_parser.zig`](../src/document/css_parser.zig). Frame rules
borrow the browser's default rules and own document rules, distinguished by
`CSSRule.owned`.

Style and layout values use `ProtectedField`. A dependency registers a raw
target pointer and callback in the dependency's `invalidations` map.
`ProtectedField.deinit` only destroys the field's own map; it does not remove
that field from maps in its dependencies. See `addDependency`,
`addInvalidation`, `notify`, and `deinit` in
[`src/core/protected_field.zig`](../src/core/protected_field.zig).

Inherited style fields establish these edges between parent and child DOM
styles in [`src/document/parser.zig`](../src/document/parser.zig). Layout fields
establish similar edges between document, parent, previous sibling, and child
layout objects in [`src/browser/render/layout.zig`](../src/browser/render/layout.zig).
The unresolved contract is how an invalidation subscriber unregisters before
its address becomes invalid.

### Layout, fonts, images, and display items

`DocumentLayout` retains both a shallow `Node` copy and the original `*Node`.
Individual block layouts also retain node pointers and install
`layout_ptr`/`layout_mark` back-pointers on elements; see
[`src/browser/render/layout.zig`](../src/browser/render/layout.zig). Layout
therefore borrows the DOM and must be destroyed before it.

`ImageLayout.pixels` borrows `ImageData.image.rawBytes()`. `FontManager` owns
font handles, glyph textures, and software-rendering pixel masks. A copied
`Glyph` borrows those resources; it does not transfer ownership. The cached
`Glyph` no longer stores the source grapheme slice, so transient input text is
not retained as glyph metadata.

Display-list container ownership is recursive: `.blend` and `.transform` own
their child slices, and `.blend` owns its copied blend-mode string. See
`DisplayItem.freeList` in [`src/browser/root.zig`](../src/browser/root.zig).
Primitive entries are not self-contained:

- `.image.pixels` borrows decoded image memory;
- `.glyph.glyph` borrows `FontManager` texture/pixel resources;
- `.iframe.node`, `.blend.node`, and `.transform.node` borrow DOM identity;
- composited-layer entries borrow layer allocations.

These leaf resources must outlive every frame-side and browser-side display
list that references them.

### Network responses and URLs

`HttpResponse.body` in [`src/network/url.zig`](../src/network/url.zig) is an
untagged slice with no destructor. `Browser.fetchBody` returns allocated bodies
for file and HTTP paths, a slice into `Url.path` for `data:`, and borrowed data
for `about:`. Callers currently infer ownership again from the URL scheme.

`Url` wraps an owning `ada.Url` and has an explicit `free` method. Its component
slices borrow that owner, except for separately allocated data-URL storage.
Ordinary Zig value copies of `Url` are shallow. Treat `Url` as move-only unless
a function is explicitly documented to borrow it, and use `Url.clone` when an
independent owner is required. `clone` rebuilds independent Ada and data-URL
storage. Root and child navigation keep the prior URL owner alive through the
synchronous fetch; async XHR clones its target and referrer before leaving the
tab worker.

`view-source:` now replaces the wrapper Ada URL with the parsed inner Ada URL
before exposing the inner component slices. That inner URL is the one released
by `Url.free`; see `Url.init` in [`src/network/url.zig`](../src/network/url.zig).

## Thread ownership and synchronization

### Main/UI/render thread

The process main thread owns the SDL event loop and browser composition,
raster, and draw phases. It also handles chrome, window events, screenshot
output, and some direct reads or updates of active `Tab`/`Frame` state.

### Tab worker

Each `TaskRunner` in [`src/runtime/task.zig`](../src/runtime/task.zig) owns a
queue of `Task` values and executes one task at a time on its worker. A `Task`
owns its opaque context through one of these paths:

- execute `run_fn`, then call `cleanup_fn`; or
- if discarded before execution, call `cleanup_fn` while clearing the queue.

Scheduling after shutdown immediately invokes cleanup. This is a useful local
contract. `TaskRunner.shutdown` publishes quit, cleans queued work, and joins
the active worker; after it returns, neither the runner nor an active task
context is borrowed by that worker.

### Detached helpers

`Browser.scheduleSetTimeoutTask`, `scheduleAnimationFrame`, and
`scheduleAsyncXhr` in [`src/browser/root.zig`](../src/browser/root.zig) spawn
detached OS threads. A Tab-level mutex, condition, and reference count provide a
logical join point: helper teardown releases the reference as its final owner
access, and `Tab.shutdown` waits for zero before document destruction. Helpers
carry copied `DocumentHandle` values rather than `Frame` or `JsRenderContext`
pointers.
Long timers poll the tab shutdown flag and exit promptly. Async HTTP still has
no request cancellation, so shutdown can safely wait but may wait for network
I/O to finish.

### Current locks

- `Browser.lock` protects a subset of active-tab render state, dirty flags, and
  shutdown/animation flags.
- `TaskRunner.mutex` and its condition protect the task queue and worker flags.
- `http_client_mutex` serializes the shared HTTP client and cookie jar around
  HTTP requests.
- `JsLock` is a recursive-by-thread-ID wrapper used around evaluation and many
  callback operations in [`src/script/js.zig`](../src/script/js.zig).

There is no general `Tab`/DOM/Layout/FontManager lock. A future contract should
prefer clear owner threads and immutable snapshots over extending one coarse
lock across parsing, layout, JavaScript, and rendering.

## Navigation contract

### Current root-frame sequence

`Browser.loadInTab` in [`src/browser/root.zig`](../src/browser/root.zig):

1. borrows the prior URL as referrer and fetches/decodes while its owner and old
   document remain alive, so a fetch/decode failure preserves the old page;
2. clears queued old-generation tasks and invalidates JavaScript roots and host
   callbacks;
3. retires browser-side draw/layer/display snapshots under `Browser.lock`;
4. destroys the old root `Frame`, including layout, DOM, and source backing;
5. allocates and registers a new root `Frame`;
6. transfers the decoded body to the frame as backing storage for the DOM;
7. stages stylesheet source buffers and parsed rules together;
8. assigns a unique document generation, parses scripts, builds layout/paint
   state, and commits browser-visible data;
9. adds the URL to history.

`Tab.invalidateJsContext` in [`src/browser/tab.zig`](../src/browser/tab.zig)
zeros every current frame's document generation, clears its embedded
`JsRenderContext`, and calls `Js.setNodes(..., null)`. The old frame is
deinitialized only after this invalidation.

### Current child-frame sequence

Child-frame navigation reuses a `Frame` allocation.
`Browser.resetFrameForNavigation` first clears JS node roots and render-context
pointers, then destroys children, display state, layout, the old DOM, owned
rules, stylesheet text, and finally decoded HTML and URL backing. The fetch
happens before reset so the referrer remains valid, and browser-side render
state is retired under `Browser.lock` before reset frees document resources.
Installing the replacement assigns a fresh per-document generation.

### Stylesheet generation transfer

Root and child navigation build `new_css_texts` and `all_rules` as one staged
generation. Error cleanup owns both staging collections until success. Only
after parsing and sorting succeed does the code replace `frame.css_texts` and
`frame.rules`. Rules and the source slices they borrow therefore cross the
ownership boundary together. Accessibility-driven stylesheet rebuilding also
constructs a complete replacement rule generation before retiring the old one;
see `loadInTab`, `loadInFrame`, `loadIframe`, and `rebuildTabStyleRules`.

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

The tab worker styles, lays out, paints, and creates a frame-side display list.
`Browser.commit` receives that list under `Browser.lock`, recursively clones
`.blend` and `.transform` child lists and blend-mode strings, frees the incoming
containers, and installs the clone as `active_tab_display_list`; see
`cloneDisplayItem`, `cloneDisplayItemList`, and `commit` in
[`src/browser/root.zig`](../src/browser/root.zig). Other variants are copied by
value.

The clone separates display-list container ownership from the tab worker, but
it still borrows image bytes, glyph resources, composited layers, and DOM
pointers. It is therefore not an independent resource snapshot.

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
- `Js.setNodes` changes the root, clears both handle maps, and resets callbacks
  when the root becomes null;
- `innerHTML` calls `removeHandlesForSubtree` for every removed child before
  destroying it, so descendant JavaScript handles are removed with the old
  subtree;
- `JsRenderContext` connects a frame window to Browser/Tab/Js host pointers and
  carries a generation number while it is synchronously registered with
  Kiesel;
- pending scripts, child-frame navigations, timers, XHR completions, and
  `postMessage` tasks carry a copied `(window_id, document_generation)` handle
  and resolve it only on the serialized tab worker.

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

`Tab.buildAccessibilityTree` in
[`src/browser/tab.zig`](../src/browser/tab.zig) now moves the prior generation's
string list to `previous_strings`. The previous tree and strings remain alive
through `handleLiveRegionUpdates`; a deferred cleanup releases both afterward.
The new tree uses a new `accessibility_strings` generation.

This fixes the prior name-slice lifetime violation. It does not establish a
cross-thread snapshot: main-thread hover and voice paths can still read or
mutate accessibility state while the tab worker rebuilds it. That broader
thread-ownership contract remains unresolved.

## SDL and graphics contract

`Browser.init` initializes SDL, creates a window and renderer, starts text
input, creates a renderer texture, initializes `Layout`/`FontManager`, and
creates z2d surfaces; see [`src/browser/root.zig`](../src/browser/root.zig).
`FontManager` retains the renderer, and `getStyledGlyph` can mutate font state,
render an SDL_ttf surface, and create an SDL texture; see
[`src/browser/render/font.zig`](../src/browser/render/font.zig).

The same browser-global `Layout` and `FontManager` are reachable from tab
layout/paint work and main-thread chrome/render paths. There is no shared lock
or assertion establishing which thread may access the font glyph map or
renderer. The concurrency is confirmed; whether a particular SDL backend
tolerates it is platform-dependent and must not be assumed.

Normal `Browser.deinit` now quiesces tabs first, retires display snapshots,
destroys document/network state, destroys glyph and cached textures while the
renderer is alive, tears down z2d state, stops text input, explicitly destroys
the renderer and window, and finally calls `sdl2.quit`. `Browser.init` uses
reverse-order `errdefer` rollback for SDL, window, renderer, text input,
textures, styles, Layout/FontManager, measurement, chrome, and z2d resources.

The intended SDL contract should be:

1. designate one thread as the owner of the SDL renderer and all renderer-bound
   textures;
2. marshal renderer operations to that thread, or document and enforce the
   narrower set of operations allowed elsewhere;
3. stop workers before destroying glyph textures, surfaces, renderer, or
   window;
4. destroy resources in reverse dependency order;
5. make every partial initialization path use the same ownership order.

## Shutdown contract

`Browser.finishRunLoop` publishes shutdown without relying on a delay.
`Browser.deinit` and `Tab.shutdown` enforce these phases:

1. publish shutdown and reject new browser/tab/JS work;
2. wake long timer helpers and stop/join each tab worker;
3. wait for accounted helpers, whose completion tasks are rejected and cleaned
   by the stopped runner;
4. retire browser render snapshots, then destroy tabs, frames, DOM, and JS;
5. destroy HTTP/cookie, layout, font, and z2d resources;
6. finish measurement state after no thread can record into it;
7. destroy renderer/window and quit SDL/SDL_ttf.

Async HTTP requests are not cancellable yet, so phase 3 can block on network
I/O; it remains memory-safe because HTTP, Tab, Browser, and measurement owners
stay alive through the wait.

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
6. **Shutdown owner order:** Browser publishes shutdown, joins tab workers,
   waits helpers, retires render snapshots, then destroys tabs, network, fonts,
   z2d, renderer, and window. Long timers poll cancellation and no longer delay
   close until their nominal deadline. See
   [`tests/manual/lifecycle-long-timeout.html`](../tests/manual/lifecycle-long-timeout.html).
7. **Stylesheet generation ownership:** root and child stylesheet source
   buffers and parsed rules are staged, cleaned up on error, and moved into
   `Frame` together. Rule rebuilding also preserves the prior generation until
   its replacement is complete. See the `new_css_texts`/`all_rules`
   transactions and `rebuildTabStyleRules`.
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
12. **Native initialization rollback:** `Browser.init` and `Layout.init` unwind
   previously created native/allocator resources in reverse dependency order;
   font discovery and font insertion also clean partial allocations. `Browser`
   is allocated at its final address before binding z2d `Context` to its root
   surface, avoiding a self-pointer into an init-local copy.
13. **JS context construction rollback:** origin keys and newly constructed
   Kiesel host contexts remain locally owned until insertion into the tab map,
   so allocation or map-insertion failure cannot strand either owner.

## Confirmed unresolved lifetime risks

A confirmed issue means the structural ownership gap is visible in code. It
does not mean every run will manifest a crash.

### 1. DOM identity remains address-unstable

Children live by value in resizable arrays while layout, hit-test, focus,
frame-element, accessibility, display, and JS structures store `*Node`.
`innerHTML` now clears handles for the subtree it removes, but that local repair
does not create stable identity for every other mutation or borrower. See
[`src/document/parser.zig`](../src/document/parser.zig),
[`src/script/js.zig`](../src/script/js.zig), and
[`src/browser/tab.zig`](../src/browser/tab.zig).

### 2. ProtectedField dependencies cannot unsubscribe

Dependency sources retain raw pointers to dependent fields. Dependent teardown
does not remove those entries from the source, while style/layout rebuilding
can destroy dependents before their sources. The missing reverse edge or
subscription token is visible in
[`src/core/protected_field.zig`](../src/core/protected_field.zig).

### 3. Display-list cloning does not make leaf resources independent

The browser clone recursively owns only container slices and blend-mode text;
primitive variants are copied by value. Those primitives contain borrowed
image, glyph, DOM, and layer resources. See `cloneDisplayItem` in
[`src/browser/root.zig`](../src/browser/root.zig).

Snapshot retirement now closes navigation, replacement, and shutdown paths,
but in-place DOM mutation can still retire a leaf before the replacement commit
reaches the browser. The clone is not independently safe by type.

### 4. Shared Layout, FontManager, and renderer access has no global contract

The browser owns one mutable layout/font stack. Resize and chrome/render paths
use it from the main thread, while tab tasks use it for document layout and
glyph creation. No common owner-thread assertion or lock covers these paths.
The concurrency gap is confirmed; backend-specific failure is a hypothesis.

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
  subtree mutation or layout rebuild;
- main-thread accessibility hit testing racing a worker rebuild and observing
  a retired tree, despite the repaired string-generation ownership;
- simultaneous main-thread and tab-thread font/SDL renderer access violating a
  backend's thread-affinity requirements;
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
- destroy Browser services before joining every task/helper that can use them;
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
but never enters compositing or rasterization. Keep these boundaries intact so
each mode can isolate a failure to one stage of the browser pipeline.
