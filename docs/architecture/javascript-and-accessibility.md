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

## Window and document generations

A `WindowContext` stores the current DOM root, raw-pointer-to-numeric-handle
maps, callbacks, timers, listeners, and named globals. `Js.setNodes` changes the
root and clears handle maps. Installing null during teardown must not call back
into JavaScript; it immediately makes wrappers inert. A later non-null install
clears and rebuilds on the serialized Tab worker before evaluation resumes.

`JsRenderContext` is the stable synchronous host-callback identity embedded in
a Frame. It carries current Browser/Tab/host pointers plus a document
generation and is cleared before Frame retirement. Asynchronous work never
retains this pointer; it carries a copied `DocumentHandle` and resolves the
live context on the Tab worker.

JavaScript node identity still ultimately maps to addresses of Nodes stored by
value in resizable child arrays. Supported mutation APIs synchronously retire
or rebind every affected handle. Future mutation APIs must use the same
boundary; an old wrapper must never silently retarget when an array address is
reused.

## DOM handles and mutation APIs

- `Node.children` returns a fresh JavaScript array of immediate Element child
  handles in DOM order, excluding Text and deeper descendants.
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
  path serializes the live DOM. `outerHTML` additionally serializes the element.

The complete structural transaction is documented in
[`document-and-rendering.md`](document-and-rendering.md). Named ID globals are
cleared before any attached pointer can move and rebuilt afterward. Detached
elements remain absent from global lookup until reattached.

## Named ID globals and returned strings

Only the active window exposes element IDs as named globals. The first nonempty
ID in document order wins; a pre-existing global wins over an ID. Refresh after
attached structure changes and attached `id` mutation. Realm activation swaps
registries and must not expose another window's Nodes.

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

XHR same-origin/CORS policy belongs to the Browser callback, not a JavaScript
shim. Both synchronous return and asynchronous `onload` move response bytes to
traced storage. An async denial intentionally schedules no `onload` because the
current API subset has no `onerror` event.

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

If z2d has no equivalent, the native method returns `error.NotImplemented` and
the host consumes it as a nonfatal `undefined`, allowing later page script to
continue.

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
- Main-thread accessibility readers do not consume a complete immutable
  document snapshot.

Tests for these boundaries should retain handles across mutation, force GC,
navigate with queued callbacks, and exercise shutdown while scripts or helpers
are active.
