# JavaScript host, DOM handles, focus, and accessibility contracts

This document is authoritative for Kiesel lifetime, JavaScript window and Node
identity, host callbacks, event delivery, timers, focus, and accessibility.
Read it before changing `src/script/`, `js_context.zig`, `script_tasks.zig`, or
Tab accessibility/focus paths.

## Kiesel host ownership

Each Tab keeps one `Js` host per origin. A host owns window contexts, DOM handle
maps, listeners, timer registries, pending messages, and callback adapters. It
is allocated from scanned uncollectable storage so the embedded Kiesel Agent is
a collector root. Any Kiesel value reachable only from ordinary Zig memory
still needs deliberate rooting.

`JsLock` serializes evaluation and many callbacks. Preserve Kiesel GC-root and
locking assumptions. A native callback entered while the lock is already held
must use the explicit native-callback helpers rather than recursively entering
an ordinary lock-taking API. Callback setters and parent-window mutation do not
yet have a fully asserted owner-thread contract; do not extend that gap.

Every tab-owned host installs a shutdown interrupt. The VM polls it at safe
points and turns it into an uncatchable host error at the evaluation boundary,
allowing Tab shutdown to join an otherwise infinite script.

Page-visible Web API shims live in `src/script/runtime/bootstrap.js` and are
embedded at compile time, then evaluated once before page code. Native
functions are installed from comptime tables. Event/focus, canvas, timer, and
network-facing functions each retain a pointer to a narrow `Host` interface
embedded in the heap-stable `Js` allocation. These interfaces expose only
current-window scalars, synchronous borrows, and copied callback arguments;
binding modules do not import the `Js` coordinator.

## Window and document generations

Each `Js` keeps one neutral host Realm on Kiesel's execution-context stack and
owns heap-stable per-document `WindowRealm` values. A non-null `Js.setNodes`
installation creates a fresh Realm/global object for that browsing-context
window id, then retires the preceding realm. A null installation is host-only:
it clears native maps/callbacks and makes wrappers inert without entering
JavaScript, so it is safe during teardown.

Each `WindowRealm` owns its current DOM root, `dom_handles.Store`, callbacks,
timers, listeners, named globals, detached roots, and bootstrap state. It can
also borrow one type-erased Node relocation observer only for a direct,
parser-blocking evaluation; that observer is cleared before parser control
yields or Realm retirement. Conversely,
`Js.nodeHandleRelocationObserver` borrows that live Realm's handle store for
parser-originated array moves, and the parser clears it before Realm
retirement. The
outer `Js` owns one monotonic `dom_handles.IdIssuer`; handle IDs therefore do
not collide across WindowRealms or document generations. A store owns the
pointer-to-ID and ID-to-pointer maps and reserves both directions before
publishing an identity. Structural relocation rebinds an existing ID; document
retirement never lets an old wrapper resolve to a newer Node.

Every entry into a page realm uses an active-window guard that restores the
previous active id on return, including error paths and synchronous reentrant
host callbacks. Page-realm initialization contexts are popped after host
bindings are installed; bootstrap and page execution each push their own
temporary Script context. Only the neutral host realm remains installed
between evaluations.

The Browser owns document lifecycle eligibility and invokes
`Js.dispatchLifecycleEvent` only through a generation-stamped task. The JS
host looks up an existing Realm before activation, so missing, retired, or
not-yet-bootstrapped documents are inert no-ops rather than new Realm
allocations. `document.readyState` reads a narrow synchronous callback over
the current Frame lifecycle phase; that callback's `JsRenderContext` is a
generation-bound borrow and returns null once its Frame is stale. Bootstrap
delivers `DOMContentLoaded` to document then window and `load` to window,
including `window.onload`; a page listener exception is contained so it cannot
prevent later listeners or lifecycle completion.

The Browser can additionally call `Js.dispatchInlineEvent` for an authored
element event attribute, such as `<body onload>`, after its generation-checked
load transition. That entry point does not allocate a missing Realm, but can
bootstrap an existing live Realm when the page has no ordinary script. The
runtime constructs a normal Event with the element wrapper as `target` and
`currentTarget`, invokes the handler with that wrapper as `this`, and contains
handler exceptions so a bad inline handler cannot prevent later lifecycle work.

`document.write` has a deliberately narrower host seam than ordinary DOM
mutation. The Browser installs a synchronous callback only around evaluation
of a parser-inserted classic script; the callback copies its temporary string
into the Frame's append-only HTML source store and gives it to the live parser
ahead of unconsumed source. The Realm clears that callback before parser
control yields. With no active sink, `document.write` is an inert bounded
operation: it must not retain a parser pointer, queue work, or imply
`document.open()` replacement semantics.

Same-origin iframe parent access is likewise a narrow capability. The
`window.parent` proxy can post messages and forward the legacy `notify(string)`
callback used by compatibility suites; it never exposes a parent DOM object or
arbitrary global property access. Cross-origin parent realms are rejected by
the host callback.

`JsRenderContext` is the stable synchronous host-callback identity embedded in
a Frame. It carries current Browser/Tab/host pointers plus a document
generation and is cleared before Frame retirement. Asynchronous work never
retains this pointer; it carries a copied `DocumentHandle` and resolves the
live context on the Tab worker.

JavaScript node identity still ultimately maps to addresses of Nodes stored by
value in resizable child arrays. Supported mutation APIs synchronously retire
or rebind every affected handle and every installed opaque relocation token.
Future mutation APIs must use the same boundary; an old wrapper or parser pin
must never silently retarget when an array address is reused.

JavaScript handles and parser pins have deliberately different retention rules
when `replaceChildren` removes a subtree: a JavaScript wrapper can remain
valid as a detached root for later reattachment, while a parser pin for that
removed subtree is retired because it can no longer name an active parser
insertion point. Parser-originated moves use the Realm-owned observer in the
opposite direction to preserve wrappers created by an earlier blocking script.

The bootstrap for each document Realm owns a cache from numeric Node ID to its
one JavaScript `Node` wrapper. Every native API that returns a Node resolves or
publishes an ID only during its synchronous callback and then passes that ID
through the cache. Thus a node reached through document lookup, traversal,
events, named ID globals, canvas, or a mutation result compares by JavaScript
object identity. The cache is never shared across document Realms.

`dom_mutation.Context` is a synchronous borrow of one window's handle and
detached-root stores. Its structural transactions stage allocations before
invalidation, temporarily unpublish pointer keys only during the non-fallible
move, and repair both handle directions before returning. Paired host hooks
clear and rebuild ID globals and notify document/layout owners without giving
the mutation module access to the realm coordinator. An optional core
`RelocationObserver` carries parser-local scalar tokens through the same
transaction without coupling the mutation module to parser types; an old
pointer passed to it is an opaque map key and may not be dereferenced.

## WPT testharness result bridge

The first WPT adapter configures its standalone `Browser` with a generic
top-level-Realm observer before creating the Tab. When the Browser installs a
document, it calls `Js.setNodes` first and invokes that observer for the
resulting top-level `WindowRealm` immediately afterward, before the live parser
can evaluate its first script. The WPT Session's observer attaches
`Js.setWptReportCallback`; ordinary Browser coordination remains unaware of the
test protocol. This ordering is required: setting the callback on an earlier
Realm and then calling non-null `setNodes` would retire that Realm and discard
the callback. Every replacement document needs a fresh callback installation.

Runtime bootstrap calls the native `wptEnabled` operation exactly once. An
enabled Realm receives `self === window === globalThis` and the WPT external
`completion_callback`; an ordinary Realm does not receive those WPT globals.
Top-level `window.parent` returns `window`, while the existing child proxy
remains the narrow postMessage/compatibility capability described above. The
official `testharness.js` external callback supplies the subtests and harness
status. Bootstrap converts them to one JSON object containing:

- top-level `status`: `PASS`, `FAIL`, `ERROR`, or `TIMEOUT`;
- `harness`: status name, numeric code, message, and stack;
- `tests`: each subtest's name, status name, numeric code, message, and stack.

A harness timeout maps to `TIMEOUT`; another non-OK harness status maps to
`ERROR`. With an OK harness, a timed-out subtest maps the aggregate to
`TIMEOUT`, another non-passing subtest maps it to `FAIL`, and an all-passing
set maps it to `PASS`.

`wptReport` converts the JSON string to temporary native bytes and invokes the
Realm callback synchronously while `JsLock` is held. The callback may not
retain that slice or re-enter `Js`, DOM, or Frame work. The current Session
callback copies the first report into a pending candidate in a
mutex-protected, heap-stable mailbox and returns. The Session thread promotes
that candidate only after the reporting Tab has returned from its active task
and its current serialized queue is empty. At or after the monotonic deadline,
`TIMEOUT` instead retires any undrained candidate. A promoted result or timeout
seals the mailbox and later completion calls are ignored. The Session remains
alive through normal Browser teardown, which retires the Realm and clears the
callback before the callback context or mailbox is freed.

Bootstrap enablement is not dynamic. Clearing a sink after bootstrap does not
remove the JavaScript `completion_callback`, and installing a sink after
bootstrap does not add one. Keep the callback and its context live from before
bootstrap until a terminal report or Realm retirement. A native reporting
failure yields no valid completion and is handled by the outer session
deadline rather than inferred as a pass.

This milestone is a result-transport bridge, not complete WPT semantics. Its
focused script tests invoke a fake external completion callback; they do not
yet prove an unmodified upstream `testharness.js` test. The bridge does not
capture assertion metadata beyond subtest message/stack, console output,
network errors, uncaught exceptions, rejected promises, test/revision
identity, or lifecycle timestamps. It publishes synchronously at the harness
callback, then the Session applies a task-return/current-queue barrier before
accepting the copied candidate. Each outer Browser-to-JavaScript turn drains
the Agent's Promise job queue to a fixed point while its `ActiveWindow` and
`JsLock` remain installed, before the Tab task can satisfy that barrier.
Nested native re-entry relies on the outer turn's checkpoint. Host interruption
is checked again after the drain so an interrupted Promise chain is reported as
`ExecutionInterrupted` even though Kiesel's drain operation contains job
errors.

This checkpoint is not a resource-quiescence predicate. Same-origin document
Realms also share one Agent: Kiesel changes its running Realm for each queued
job, but Zibra's native bindings still route through the outer
`current_window_id`. Promise jobs belonging to another same-origin Realm must
not be treated as correctly routed until that mapping is explicit. Kiesel also
has no Zibra rejection-tracker hook, so unhandled rejections are not yet
structured harness diagnostics. Only the top-level Realm contributes the
terminal result; child browsing-context aggregation and ordinary-page `self`
support remain outside this first slice. The Browser Session, not JavaScript
bootstrap, owns the monotonic deadline, crash/load error classification,
teardown, and final machine-readable result wrapper.

## DOM handles and mutation APIs

- `Node.children` returns a fresh JavaScript array of immediate Element child
  wrappers in DOM order, excluding Text and deeper descendants.
- Read-only tree bindings provide `document.documentElement`, `document.body`,
  `getElementById`, document/Element `getElementsByTagName`, and authored Node
  parent/sibling/child/text traversal. These APIs resolve the live tree rather
  than named ID globals; tag-query and child arrays are deliberate snapshots,
  not live HTMLCollections. Generated pseudo boxes remain private.
- NodeIterator keeps a reference node plus its before/after pointer state,
  applies whatToShow and filters in document order, forwards filter exceptions
  without advancing, and retains the last traversal order so a mutation
  performed by a filter can still be traversed correctly.
- TreeWalker keeps currentNode stable until a navigation method succeeds;
  child/sibling/parent navigation honors filter accept, reject, and skip
  results, while nextNode and previousNode traverse only within root.
- Text topology is readable through `childNodes`, `nodeType`, `nodeName`,
  `nodeValue`, `data`, and `textContent`. Text mutation and creation remain a
  separate ownership/invalidation boundary because parser-created text borrows
  document source storage.
- `document.createElement` creates a lowercase-tagged, window-owned,
  heap-stable detached root.
- `appendChild` and `insertBefore` transfer an eligible detached root, preserve
  its handle, and rebind siblings relocated by insertion.
- `removeChild` accepts a direct child, moves its subtree to heap-stable
  detached ownership, preserves subtree handles, rebinds shifted siblings, and
  returns the same root.
- `replaceChildren` stages all attached/detached Element arguments, validates
  cycles and handles before invalidation, removes sources deepest-first, keeps
  only the last occurrence of a repeated root, and installs argument order in
  one mutation generation. Published removed subtrees remain detached and
  reattachable. Unsupported non-Element arguments throw before mutation.
- `innerHTML` removes handles recursively before old children retire; its read
  path serializes the live DOM. Its replacement parser creates an inert HTML
  fragment: scripts in that fragment are marked started before installation,
  so a later resource refresh cannot execute scripts resurrected by
  serialization/reparse. `outerHTML` additionally serializes the element.

The complete structural transaction is documented in
[`document-and-rendering.md`](document-and-rendering.md). Named ID globals are
cleared before any attached pointer can move and rebuilt afterward. Detached
elements remain absent from global lookup until reattached.

## Named ID globals and returned strings

Each document Realm exposes its own element IDs as named globals. The first
nonempty ID in document order wins; a pre-existing page global wins over an
ID. Refresh after attached structure changes and attached `id` mutation. No
global-registry swap may expose another frame's Nodes.

DOM serialization, cookie values, XHR response text, message data, and other
temporary host strings must move into Kiesel's traced allocator before native
buffers are released. Kiesel's ASCII string construction may retain the input
bytes instead of copying them.

## Events and default actions

Listener maps are scoped by window. A bubbling event snapshots a
target-to-root path of numeric handles before invoking JavaScript. Reuse one
Event object, keep `target` fixed, and update `currentTarget` for each node.
`stopPropagation` allows remaining listeners on the current node before
stopping the next ancestor; `preventDefault` independently cancels the browser
action.

The event/focus native binding receives only an active-window borrow containing
the root, handle store, and optional focus callback. That borrow ends with the
Kiesel call; bubbling continues from its numeric snapshot even if a listener
relocates the original Nodes.

Browser-generated focus and blur events are target-only. Click, key, form, and
submit events follow their supported bubbling behavior. Default anchor, input,
button, or contenteditable actions resolve a previously captured stable handle
after listeners return, because listeners may structurally mutate the target.

## Focus and modality

`document/focus.zig` is the one intrinsic policy used by JavaScript focus,
layout bounds, and sequential traversal. Programmatic focus accepts explicit
negative tabindex; keyboard traversal does not. Hidden or disabled controls and
`contenteditable=false` are rejected. Current layout visibility remains a
separate generation check.

`Node.focus()` transfers only a numeric handle through the synchronous native
callback. The Tab completes pending style/layout first, requires the target in
the current focus-bounds snapshot, clears and dispatches old blur state,
re-renders/re-resolves after listener mutation, scrolls the new bounds into
view, then installs focus and dispatches focus. It publishes stable Tab identity
to the UI thread when Chrome's private address input must blur.

Only one Frame may retain content focus. Sequential Tab traversal visits root
and descendant Frames in preorder, exhausts each document's DOM-order focus
stops before entering child Frames, skips empty Frames, and wraps only after the
complete frame tree. Shift-Tab is the reverse.

The Tab records pointer or keyboard modality. Pointer-focused links/buttons do
not show the native ring; visible text inputs/contenteditable targets do.
Keyboard interaction promotes existing and future focus to visible. Store that
decision in `Element.is_focus_visible`, dirty style at each transition, and use
the same snapshot for `:focus-visible` and native focus paint.

Chrome focus transitions enqueue `Tab.blur`; they do not mutate Frame raw
pointers from the UI thread. Structural DOM mutation, navigation, and Frame
teardown clear any focus or element-scroll pointer that no longer names a live
node.

## Timers, XHR, and postMessage

Timer callback registries are scoped by JavaScript window. Timeout callbacks
are removed before invocation. `setInterval` reschedules one generation-stamped
one-shot only after a live callback completes. `clearInterval` removes both
JavaScript and native cancellation keys; old queued deliveries become no-ops.

Timer native bindings forward only a numeric handle, clamped delay, and repeat
flag through their host interface. The binding never retains the callback,
document, or window; the embedded runtime and browser scheduler remain owners.

XHR same-origin/CORS policy belongs to the Browser callback, not a JavaScript
shim. Both synchronous return and asynchronous `onload` move response bytes to
traced storage. An async denial intentionally schedules no `onload` because the
current API subset has no `onerror` event.

Cookie, XHR, and postMessage argument buffers are callback-scoped. The network
binding copies callback-owned response text into Kiesel's traced allocator
before releasing it and forwards policy decisions to browser-owned callbacks.

`postMessage` parses target origin synchronously:

- `*` is unrestricted;
- `/` snapshots the sender's origin;
- any other value must be an absolute URL and is retained as scheme, host, and
  effective port.

The queued task owns that policy, serialized source origin, and message copy.
Resolve the target document and enforce the policy only at delivery. A
cross-origin `window.parent` is an opaque numeric proxy exposing only
`postMessage`; it does not install the parent's DOM realm.

## Canvas bindings

Canvas wrappers are window-scoped and cached by stable Node handle so repeated
`getContext("2d")` calls return the same object. Native canvas backing is
heap-stable. Pixel-changing commands dirty retained paint and request paint;
path/state-only commands do not. Assigning either dimension resets native
pixels/path/transform and wrapper paint state even when the value is unchanged.

The canvas binding resolves an Element through a synchronous host borrow. It
owns command validation and backing-store operations, but returns no DOM
pointer and requests rendering only through its host callback.

If z2d has no equivalent, the native method returns `error.NotImplemented` and
the host consumes it as a nonfatal `undefined`, allowing later page script to
continue.

## DOM ranges and detached content

`document.createRange()` is implemented in the page Realm. Range boundary
points borrow the Realm's canonical Node wrappers and are evaluated through
their current parent/child relationships, so a range never retains a native
DOM pointer across a callback. `DocumentFragment` and comment nodes are
Realm-owned detached values; appending a fragment transfers its children, and
extracting content preserves fully selected native node identities while
cloning only partially selected structure. Text splitting uses the synchronous
`setNodeData` binding and therefore stays within the active DOM mutation
phase. Active ranges are adjusted when a containing subtree is removed, and
text insertion remaps split-text offsets so boundary points continue to denote
the same content.

## Accessibility tree and speech

Accessibility-tree strings belong to their tree generation. During rebuild,
keep the prior tree and string list alive through live-region diffing, then
release both. Reading/highlight pointers are remapped through live DOM nodes
before the old tree retires; clear them if the node disappeared.

Document reading advances one preorder accessibility node per request, skipping
the synthetic document root for the first visual step. It stores that node for
the amber highlight and queues a complete owned speech string. Password backing
values are never copied into names, logs, or speech.

The accessibility runner owns queued utterances; no page pointer crosses to
it. Stop the Tab runner first so no producer remains, then clear/join speech,
then retire tree strings and shared measurement.

Main-thread accessibility readers still lack a comprehensive immutable
snapshot contract while the worker rebuilds. Queue new hit or mutation work to
the serialized Tab worker rather than adding another cross-thread raw borrow.

## Forced colors and visual focus

Forced-colors mode is Tab state supplied to every Frame media environment.
Changing it rebuilds conditional rules and invalidates style, layout, and
paint. Render classifies CSS colors by semantic role and maps them to the fixed
black/white/cyan/yellow palette. Transparent paint remains transparent; content
images and color glyphs are not recolored; decorative background images are
suppressed.

Focus-visible paint uses pointer-free commands emitted after document content:
a 4px white outline beneath a 2px black outline. Inline focus targets retain
one rectangle per wrapped line across nested descendants; focusable blocks use
one complete block box. The amber screen-reader highlight is separate.

## Known gaps

- Stable JavaScript Node identity is not enforced by the type system.
- Some JavaScript host mutations have only an implicit owner-thread rule.
- WPT reporting lacks upstream-harness integration coverage, cross-Realm
  Promise-job routing, unhandled-rejection and other diagnostic capture,
  resource-quiescence completion, and child-context aggregation.
- Main-thread accessibility readers do not consume a complete immutable
  document snapshot.

Tests for these boundaries should retain handles across mutation, force GC,
navigate with queued callbacks, and exercise shutdown while scripts or helpers
are active.
