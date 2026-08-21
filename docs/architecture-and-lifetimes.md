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
| [`src/browser/root.zig`](../src/browser/root.zig) | Per-window `Browser`, navigation orchestration, fetch coordination, async host helpers, render commit, composition, raster, and draw; it also supports standalone headless construction. |
| [`src/browser/tab.zig`](../src/browser/tab.zig) | `Tab` and `Frame` ownership, task serialization, history, frame lookup, accessibility, focus, and per-document state. |
| [`src/browser/chrome.zig`](../src/browser/chrome.zig) | Browser-owned internal HTML chrome, its dedicated layout/font state, semantic actions, address editing, and retained display data. |
| [`src/browser/session_state.zig`](../src/browser/session_state.zig) | Window-independent HTTP client/cookies/cache plus visited/bookmarked URL state, generated bookmark HTML, and separate network/metadata synchronization. |
| [`src/browser/render/layout.zig`](../src/browser/render/layout.zig) | Layout tree, invalidation dependencies, hit-test collection, paint, and image layout. |
| [`src/browser/render/font.zig`](../src/browser/render/font.zig) | Font discovery, SDL_ttf handles, Unicode fallback selection, and owned RGBA glyph bitmaps. |
| [`src/document/parser.zig`](../src/document/parser.zig) | HTML parser, DOM representation, style maps, images, and DOM tree utilities. |
| [`src/document/inspection.zig`](../src/document/inspection.zig) | Browser-free fetch/decode/parse/style pipeline for document inspection commands. |
| [`src/document/css_parser.zig`](../src/document/css_parser.zig) | CSS parsing and `CSSRule` ownership. |
| [`src/document/selector.zig`](../src/document/selector.zig) | Selector representation and matching. |
| [`src/network/url.zig`](../src/network/url.zig) | Owning `Url`, URL resolution, schemes, HTTP requests, redirects, cookies, response bodies, and cache integration. |
| [`src/network/cache.zig`](../src/network/cache.zig) | Browser-session HTTP response entries, expiry, and strict `Cache-Control` policy parsing. |
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
  interactive BrowserApp
    sole SDL event poller and text-input owner
    shared BrowserSession (HTTP/cookies/cache/visited/bookmarks)
    shared MeasureTime
    native window registry
      Browser A                 Browser B ...
        tabs/chrome/render        tabs/chrome/render
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
          | spawns accounted helper threads
          v
    setTimeout thread(s), animation timer thread, async XHR thread(s)
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
| SDL and SDL_ttf | BrowserApp owns interactive SDL/text input, each Browser owns its native window/renderer/texture, and each `FontManager.deinit` frees cached RGBA glyph bitmaps, closes fonts, and releases its paired SDL_ttf reference. The App holds an extra refcounted SDL_ttf guard until all windows close. | Native handles require deterministic release and an explicit thread-affinity rule. |
| z2d and zigimg | `Browser` owns long-lived z2d surfaces/contexts. `ImageData` owns a `zigimg.Image` and, when present, its encoded byte buffer; see [`src/document/parser.zig`](../src/document/parser.zig). | Layout and display items borrow pixel slices from these owners. The source image must outlive every borrower. |

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

`BrowserSession` owns the shared `std.http.Client`, cookie jar, decoded HTTP
response cache, and canonical serialized strings for visited and bookmarked
URLs. A dedicated network mutex serializes transport/cookie/cache access; its
metadata mutex protects both URL sets independently of every `Browser.lock`.
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

- indexed URL history entries and the current-entry index;
- a sentinel-terminated copy of the current root document's title;
- one root `Frame`, which recursively owns child frames;
- one Kiesel `Js` context per origin key;
- frame-ID maps plus tab-wide and per-document generation counters;
- the `TaskRunner` and accounting for detached helper threads;
- dynamic text allocations;
- the accessibility tree and its backing strings;
- per-tab dirty flags and composited updates.

`Tab` borrows its `Browser` and the heap-stable `MeasureTime` used by its
`TaskRunner`. That measurement owner is BrowserApp in interactive mode and the
standalone Browser in screenshot mode.

### Frame

`Frame` in [`src/browser/tab.zig`](../src/browser/tab.zig) owns:

- child `Frame` allocations;
- the document's decoded HTML source;
- the root DOM `Node` value;
- document layout and the frame-side display list;
- owned CSS rules and their source buffers, including decoded linked sheets
  and copied `<style>` text retained in DOM order;
- hit-test collections, fragment target positions, and allowed-origin strings;
- a frame-owned URL only when `current_url_owned` is true.

The root frame normally borrows its URL from `Tab.history`; child frames may
own their URL. `parent`, `tab`, `frame_element`, focus pointers, hit-test node
pointers, `js_context`, and layout-related node pointers are borrowed.

Structural DOM mutation also marks the affected frame's resources dirty. On
the serialized tab worker, after the JavaScript host call has completed and
before the next style pass, the browser scans the final attached tree. Newly
attached classic scripts are copied into queued tasks and their DOM elements
record that evaluation has started; this identity moves with remove/re-attach,
while evaluated code remains in the document realm. Author stylesheets are
rebuilt as a staged rules-plus-source-buffer generation from the current DOM,
which both loads inserted `<style>`/`<link>` elements and retires rules from
detached links without leaving property slices pointing at freed CSS text.

Each tab records the visited generation represented by its display list. A new
session visit requests an animation frame; render compares generations before
its early dirty check, re-annotates every current frame, and forces paint when
stale. A middle-click records the target before transferring its owning URL to
the pending-tab queue, so the still-visible source document can repaint at
once; stale background documents refresh when activated.

History is mutated only by the serialized tab worker. Ordinary successful
navigation removes and releases entries after the current index before
appending the new URL. Back and Forward retain the list, clone the target URL
for loading, and update the index only after the replacement document is
ready; a failed traversal therefore leaves both the prior document's history
position and every canonical history URL owned. Chrome does not read the
history collection concurrently. It reads acquire/release atomic availability
flags and schedules a traversal task, which revalidates the requested move on
the worker.

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
that the replacement removes.

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

Display-list container ownership is recursive: `.blend` and `.transform` own
their child slices, and `.blend` owns its copied blend-mode string. See
`DisplayItem.freeList` in [`src/browser/root.zig`](../src/browser/root.zig).
`BlockLayout.display_list` is a persistent paint cache and recursively owns
any such containers stored in it. Painting a frame deep-clones cached items
before wrapping them in effects or transferring the resulting snapshot; frame
retirement must therefore free only the clone and leave the cache reusable for
paint-only animation frames. Relayout recursively releases cached containers
before replacing the cache.
Primitive entries are not self-contained:

- `.image.pixels` borrows decoded image memory;
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

`DisplayItem.hitTestDevice` is a pure walk over the retained frame list. It
visits items in reverse paint order, inverts translation transforms, treats
`dst_in` masks as clipping operators rather than click targets, and checks
primitive paint geometry. Native click tasks retain the exact device point and
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
Compositor-only opacity
animation updates also mutate the retained effect wrapper before the same
update is committed, so invisible content stops participating in hit testing.
The browser applies that update recursively through transforms in its committed
tree; effects flattened into an ancestor or iframe layer update the layer-owned
tree and mark its cached pixels for rerasterization.
Layout-derived link and iframe bounds no longer decide click targets. Focus,
accessibility, and fragment bounds retain their existing roles.

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
`BrowserSession.network_lock` serializes its HTTP client, cookie jar, and cache
across tabs and native windows without nesting the visited/bookmark mutex.

Every document Frame stores the Referrer-Policy parsed from its response.
Navigation, images, iframes, scripts, stylesheets, and XHR pass both that policy
and the source URL into the network layer. Referer generation omits fragments;
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
existing navigation URL pointer before parsing subresources or committing
history, so the frame, relative URLs, history, and chrome all use the final
destination without adding URL ownership to ordinary subresource responses.
For a Back or Forward traversal, that final URL replaces the canonical entry at
the destination index; this keeps redirected traversal and subsequent history
moves consistent.

`view-source:` now replaces the wrapper Ada URL with the parsed inner Ada URL
before exposing the inner component slices. That inner URL is the one released
by `Url.free`; see `Url.init` in [`src/network/url.zig`](../src/network/url.zig).

## Thread ownership and synchronization

### Main/UI/render thread

The process main thread owns every Browser's composition, raster, and draw
phases. In interactive mode, BrowserApp is the sole SDL event poller and text
input owner. It derives the native ID from key, window, text-editing/text-input,
mouse, drop, and user event payloads, ignores stale IDs, and forwards each
event only to its addressed Browser. Nonrepeating Ctrl+N from a live source
creates an `about:blank` native window; allocation or renderer failure logs and
leaves existing windows alive. Window-close events remove only their addressed
entry, SDL quit is global, and Escape routed through any live Browser is the
documented global shortcut. After event dispatch, the App broadcasts shared
session generations and ticks composition/raster/draw for every window. In
screenshot mode a standalone Browser instead runs a windowless quiescence loop
and exports the software root surface directly. Page workers never mutate the
tab collection: a middle-click resolves its link target on the serialized tab
worker, transfers the owning URL into `Browser.pending_new_tabs` under
`Browser.lock`, and the containing Browser's tick drains that queue before
creating and activating tabs in the same native window.
`queueNewTab` transfers ownership only when append succeeds; `newTab` consumes
the URL on entry so every creation and scheduling failure has one clear owner.
Root navigation also copies the first DOM `title` into tab-owned sentinel
storage under `Browser.lock`. The App tick applies each window's dirty active
title to its SDL handle; switching tabs uses the same activation path and marks
it dirty.
Chrome's Back and Forward handlers read only atomic availability snapshots and
enqueue a history task. The worker computes the target again before loading,
so a click based on a stale disabled/enabled snapshot is harmless.
History entries are heap-stable owners of a URL, an explicit GET/POST method,
and an independent POST-body copy. A navigation prepares the entry, body copy,
and list capacity before retiring the current document, then transfers both the
URL and prepared entry only after the replacement document is ready. Replacing
or truncating entries frees their URL and POST bytes together.

A GET history target is cloned and replayed directly on the tab worker. A POST
target does not change the index or document; instead the worker publishes a
tab pointer, target index, and history generation under `Browser.lock`. The
interactive SDL thread consumes that request and displays a native modal
confirmation without holding the lock. Cancel schedules nothing. Resubmit
queues a task back to the originating tab, which validates the generation,
copies the retained body for the load, and commits the new index only after the
POST succeeds. Tab switches, shutdown, stale generations, dialog failures, and
headless operation all cancel rather than replaying state-changing data.
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
new URL, append it to indexed root history (or replace an iframe-owned URL),
apply the clamped layout target, and request a paint commit. The existing DOM,
JavaScript state, form controls, and document generation remain intact. Middle
click still transfers the resolved URL to a new tab instead.

Window resizing preserves that ownership boundary. The main thread allocates a
complete replacement generation of the root/chrome/tab z2d surfaces and SDL
texture before retiring the live generation, updates chrome geometry, and then
queues viewport snapshots to each tab. Obsolete drag-resize snapshots are
discarded by generation. A tab worker updates its root-frame viewport, marks
every frame layout dirty, re-clamps scroll, and requests the active tab's next
animation frame; it does not mutate native render targets.

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

- `Browser.lock` protects a subset of active-tab render state, dirty flags,
  shutdown/animation flags, and the independently owned optimistic-display and
  committed-document URL snapshots used by chrome. The committed snapshot's
  security state is published in the same commit: chrome emits a padlock only
  for a matching, verified HTTPS document, never for optimistic navigation
  text or a certificate-warning document.
- `TaskRunner.mutex` and its condition protect the task queue and worker flags.
- `BrowserSession.network_lock` serializes the shared HTTP client, cookie jar,
  and response cache across every window around fetches and synchronous
  `document.cookie` callbacks. A callback never retains a jar slice after
  releasing this lock.
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
8. stages stylesheet source buffers and parsed rules together;
9. assigns a unique document generation, parses scripts, builds layout/paint
   state, and commits browser-visible data;
10. applies any final-URL fragment to the completed layout and clamps the frame
   scroll range;
11. commits the final URL by appending it to indexed history, or by replacing a
   successfully traversed entry and moving the current index.

`Tab.invalidateJsContext` in [`src/browser/tab.zig`](../src/browser/tab.zig)
zeros every current frame's document generation, clears its embedded
`JsRenderContext`, and calls `Js.setNodes(..., null)`. The old frame is
deinitialized only after this invalidation.

### Current child-frame sequence

Child-frame navigation reuses a `Frame` allocation.
`Browser.resetFrameForNavigation` first clears JS node roots and render-context
pointers, then retires provenance-bearing display state before destroying
children, layout, the old DOM, owned
rules, stylesheet text, and finally decoded HTML and URL backing. The fetch
happens through the same owned `NavigationDocument` helper before reset so the
referrer and its copied policy remain valid, and browser-side render
state is retired under `Browser.lock` before reset frees document resources.
Installing the replacement assigns a fresh per-document generation. Initial
iframe loads and later navigation within an existing child frame check both the
requested and final redirect destinations against the parent document's CSP
before recording the visit or installing the child.

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
  a separate, non-destructive invalidation path;
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
second main-thread-only pair. Interactive mode still lacks a shared lock or
assertion establishing which thread may access
each font glyph map or SDL_ttf handle. Screenshot mode closes that race by
refusing to raster until the serialized tab worker and all accounted helpers
are quiescent. The renderer no longer participates in glyph-cache mutation.

Normal `Browser.deinit` quiesces its tabs first, retires display snapshots,
destroys document state, frees cached glyph bitmaps and closes fonts, tears
down z2d state, then destroys that window's texture, renderer, and native
handle. An App-owned Browser leaves shared session, measurement, text input,
and SDL untouched. After all entries are gone, BrowserApp destroys the shared
network/session state, finishes measurement once, stops text input, releases
its final SDL_ttf guard, and quits SDL. Standalone Browser owns those same final
steps itself. Both constructors use reverse-order `errdefer` rollback.

The intended SDL contract should be:

1. designate one thread as the owner of the SDL renderer and all renderer-bound
   textures;
2. separately serialize mutable SDL_ttf font and glyph-cache access;
3. stop workers before freeing glyph bitmaps or destroying fonts, surfaces,
   renderer, or window;
4. destroy resources in reverse dependency order;
5. make every partial initialization path use the same ownership order.

## Shutdown contract

`Browser.deinit`, `Tab.shutdown`, and BrowserApp teardown enforce these phases:

1. publish shutdown and reject new browser/tab/JS work;
2. wake long timer helpers, interrupt JavaScript running on each tab worker,
   and stop/join the workers;
3. wait for accounted helpers, whose completion tasks are rejected and cleaned
   by the stopped runner;
4. retire browser render snapshots, then destroy tabs, frames, DOM, and JS;
5. destroy each Browser's layout, font, z2d, renderer, and window resources;
6. after the final Browser is gone, destroy shared HTTP/cookie/cache/session
   state and finish measurement once, when no thread can record into either;
7. stop text input, release the App's SDL_ttf guard, and quit SDL.

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
