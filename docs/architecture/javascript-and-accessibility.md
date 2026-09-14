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

`src/script/gc_threads.zig` is the process collector-initialization boundary.
Both `Js.init` and lock-taking host entry register the calling native thread
before accessing Kiesel. Registration belongs to that OS thread until pthread
exit, not to the host, realm, lock, or callback: an evaluated Value can remain
live on the caller's stack after evaluation returns. Hosts may be destroyed on
a different thread after their workers join; that thread must register too.
The pthread destructor unregisters exactly the registrations Zibra owns,
including GC's implicit initial registration when the first caller is a
short-lived worker. Existing foreign registrations are borrowed. Initialization
is serialized so multiple first-use callers cannot race Kiesel's init guard.
This uses the same linked collector and allocation options as Kiesel, with no
global collection disable or additional collector instance. Inability to
establish safe tracing is fatal, like collector initialization itself.

Thread registration only makes stacks visible; it does not serialize Agents,
retain ordinary Zig heap containers, or permit asynchronous raw Value borrows.

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

WindowRealm also borrows its Frame's immutable incoming referrer string and
mutable outgoing policy slot. Native readback copies the string into Kiesel
storage; metadata mutation uses the policy pointer only synchronously under
the host lock. Realm retirement clears both before Frame teardown. See the
[referrer contract](navigation-and-network.md#referrer-policy) for parsing,
request snapshots, and delivery order. Detached parsing receives no live
policy slot and cannot modify its creator's policy.

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

The Realm also weakly caches one live `children` HTMLCollection per Node
wrapper. Repeated reads return that same collection before and after mutation;
each indexed/named/length query resolves the current child snapshot, never a
retained native Node slice. `Array.from(collection)` remains an explicit static
snapshot. The cache follows Realm retirement, not document-global identity.

`dom_mutation.Context` is a synchronous borrow of one window's handle and
detached-root stores. Its structural transactions stage allocations before
invalidation, temporarily unpublish pointer keys only during the non-fallible
move, and repair both handle directions before returning. Paired host hooks
clear and rebuild ID globals and notify document/layout owners without giving
the mutation module access to the realm coordinator. An optional core
`RelocationObserver` carries parser-local scalar tokens through the same
transaction without coupling the mutation module to parser types; an old
pointer passed to it is an opaque map key and may not be dereferenced.

## Native selector queries

Document and Element subtree queries compile the same bounded, unforgiving
selector list used by stylesheets. Logical is/where members perform their own
forgiving parsing. Invalid members reject the entire ordinary list, allocation
errors propagate, and wrappers preserve SyntaxError. Matching appends each
node once in tree order even when multiple selectors match. Element wrappers
exclude the receiver itself; native document queries include the root.

Query-local selectors and relational caches retire before the callback returns.
Subtree queries prepare `:has` caches from the actual tree root so logical
arguments see ancestors outside the requested result subtree, consistent with
uncached matching. No selector or ancestry pointer is retained in JavaScript.

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

The bridge is not complete WPT semantics. Local protocol fixtures and focused
upstream cases cover result transport, while console output, structured
network failures, rejected promises, and child-context aggregation remain
incomplete. It publishes synchronously at the harness
callback, then the Session applies a task-return/current-queue barrier before
accepting the copied candidate. Each outer Browser-to-JavaScript turn drains
the Agent's Promise job queue to a fixed point while its `ActiveWindow` and
`JsLock` remain installed, before the Tab task can satisfy that barrier.
Nested native re-entry relies on the outer turn's checkpoint. Host interruption
is checked again after the drain so an interrupted Promise chain is reported as
`ExecutionInterrupted` even though Kiesel's drain operation contains job
errors.

WPT-enabled Realms additionally own `wpt_bindings.DiagnosticLog`, a bounded
stderr side channel independent of the result mailbox. Runtime hooks observe
harness startup and sparse subtest progress; outer evaluation/callback failure
paths record source labels and the VM exception before it is cleared. These
operations run synchronously under the existing JsLock, retain no source or
Kiesel value, and never re-enter JavaScript or publish a terminal result.
Ordinary and retired Realms do not emit WPT diagnostics. The per-Realm byte
budget bounds progress and reserves space for errors. Source labels supplied
to `evaluateNamed` are diagnostic-only, callback-scoped borrows; they are not
installed in retained VM executable metadata. The external runner consumes
these optional JSON stderr events, preserving evidence even on watchdog kills.
Missing startup observations and partial results do not prove a stall, and
diagnostic errors cannot override valid harness completion. Caught exceptions
remain caught; reporting errors swallowed by runtime listeners and tracking
rejected promises require separate event-delivery work.

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

- `Node.children` returns a Realm-local live `HTMLCollection` of immediate
  Element wrappers in DOM order, excluding Text and deeper descendants.
- `runtime/document_accessors.js` implements `documentElement`, `head`, `body`,
  and `title` on Document's prototype for both live and detached documents.
  The document child list is authoritative for the root: a getter must not
  create a missing element or return a removed one. Head/body match direct
  HTML children by namespace and local name; title uses child text content,
  ASCII whitespace normalization, and the separate SVG-root algorithm.
  `HTMLTitleElement.text` preserves whitespace and excludes descendant element
  text. Title/body writes use existing Node mutations and their synchronous
  invalidation/handle-rebind boundaries, not independent native pointers.
  `createElementNS` preserves local-name case; namespace metadata on these
  wrappers does not imply namespace-aware XML parsing or full element IDL.
  Live Document-level root replacement still has the bootstrap's limited
  logical topology and is not a native navigation/root-installation API.
- Read-only tree bindings provide the initial native root, `getElementById`,
  document/Element `getElementsByTagName`, and authored Node
  parent/sibling/child/text traversal. `getElementsByTagName`,
  `getElementsByClassName`, and `getElementsByTagNameNS` expose live
  `HTMLCollection` views whose indexed and named properties are virtual;
  selector results are static `NodeList` snapshots, while `Node.childNodes`
  is a cached live `NodeList` refreshed by JavaScript mutation boundaries.
  The current lightweight `attributes` records remain snapshots. Generated
  pseudo boxes remain private.
- `runtime/dataset.js` caches a live `DOMStringMap` per eligible HTML/SVG/MathML
  wrapper. It derives named properties in native attribute-list order, applies
  ASCII-only `data-*`/camel-case conversion, and supports enumeration,
  descriptors, prototype-name overrides, symbols, and removal. Direct writes
  perform DOMString conversion before validating names and call the existing
  native attribute mutation/invalidation path. No map snapshot or native
  attribute pointer survives a callback.
  Attribute methods use DOMString/arity checks, current DOM name validation,
  and ASCII lowercasing only for HTML elements in HTML documents. Detached
  document factories set their HTML/XML content type for this distinction.
  The current interface installation is per-wrapper, like title/referrer
  interfaces, not complete HTMLElement/SVGElement/MathMLElement prototype IDL.
  A JavaScript Proxy cannot emulate an explicit non-configurable named-property
  definition while reporting Web IDL's configurable virtual descriptor; these
  definitions are rejected before mutation pending native exotic-object support.
  Custom-element reactions, MutationObserver delivery, full XML namespace
  resolution, and lone-surrogate attribute DOMStrings remain outside this slice.
- Element selector results exclude the receiver. Native subtree lookup also
  serves detached Documents, which include their root; the Element wrapper
  filters that root without changing selector ancestry or Document semantics.
- NodeIterator keeps a reference node plus its before/after pointer state,
  applies whatToShow and filters in document order, forwards filter exceptions
  without advancing, and retains the last traversal order so a mutation
  performed by a filter can still be traversed correctly.
- TreeWalker keeps currentNode stable until a navigation method succeeds;
  child/sibling/parent navigation honors filter accept, reject, and skip
  results, while nextNode and previousNode traverse only within root.
- `runtime/character_data.js` supplies CharacterData/Text/Comment prototypes,
  data/length accessors, substring/append/insert/delete/replace methods,
  `Text.splitText`, `wholeText`, and `Node.normalize`. String/unsigned-long
  conversions precede the algorithm, which reads current data after possible
  conversion side effects. Node's nullable nodeValue/textContent setters and
  CharacterData's LegacyNullToEmptyString data setter share replacement but
  differ for undefined. All offsets are UTF-16 code units.
- `character_data_bindings.zig` stages independently owned data, retires live
  layout borrowers through the existing mutation hooks, and replaces only the
  native Text payload. Creation and mutation preserve exact non-ASCII UTF-16
  units alongside a scalar UTF-8 rendering projection. Parser-backed readback
  decodes supported character references once; literal DOM data never does.
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
- `innerHTML` stages a context-sensitive fragment, then replaces children in
  one structural transaction. Published removed subtrees remain detached and
  usable; wrappers, live child lists, and Range removal positions are repaired
  after native success. Fragment source is retained by the Realm independently
  of former parents. Parsed scripts are marked started before installation, so
  later resource refresh cannot execute them. `runtime/html_fragments.js`
  additionally implements writable `outerHTML` and all four adjacent-HTML
  positions using existing node-transfer APIs; surrounding nodes/listeners are
  never serialized and recreated. These multi-node transfers are synchronous
  sequences, not yet one batch mutation-observer record.

The bounded HTML fragment parser handles flow/list/paragraph recovery, implied
table sections/rows and sibling cells, and initial RCDATA/raw-text contexts.
It does not yet implement all insertion modes, foster parenting, comments,
foreign/XML fragment parsing, templates/shadow roots, or Trusted Types.
Range contextual fragments need a separate scripting-mode implementation.
Text readback distinguishes HTML character-reference source from literal XML,
raw script/style, and script-created data; it decodes the existing supported
reference set into copied strings without changing renderer source storage.
Comments, processing instructions, and CDATA remain synthetic wrapper-owned
data, not first-class native parser/render nodes. They share CharacterData
methods and Range repair, but this does not implement native comment/CDATA
parsing, mutation-observer records, PI pseudo-attributes, or complete cross-Realm
constructor/IDL semantics. Native HTML serialization still uses the scalar
UTF-8 projection for unpaired surrogates.

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

Audio controls add four internal focus parts (play, seek, mute and volume)
before traversal leaves the element. They share the audio DOM focus owner,
while native paint and accessibility use the selected part's action/slider
label. Native interaction does not dispatch author clicks. Accessibility-tree
rebuilds retain the previous tree until comparison completes and avoid speaking
an unchanged focused node/role/name on every media repaint.

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

`runtime/range.js` implements `document.createRange()` in the page Realm and
is embedded with bootstrap before page evaluation. The constructor starts in
the current document; a detached document's factory starts in that document.
Range boundary points borrow the Realm's canonical Node wrappers and are evaluated through
their current parent/child relationships, so a range never retains a native
DOM pointer across a callback. `DocumentFragment` and comment nodes are
Realm-owned detached values; appending a fragment transfers its children, and
extracting content preserves fully selected native node identities while
cloning only partially selected structure. Partial extraction and Range
insertion use the shared CharacterData replacement/split algorithms. Replacement
clamps endpoints inside removed text and shifts later endpoints. Attached
splits transfer later text endpoints to the new node and advance the exact
parent boundary after the original; detached splits clamp in the original.
Normalization merges only exclusive Text nodes, maps endpoints in merged nodes
and parent child-index boundaries, and preserves removed wrappers. CDATA and
comments are merge barriers; wholeText includes adjacent CDATA. Structural
mutation dirties sibling-sensitive selectors;
`getComputedStyle` readback invokes a Realm-scoped style-flush callback so a
script observes the new computed value synchronously, while layout and paint
remain scheduled work.

Boundary setters convert Web IDL offsets and validate before changing either
endpoint. Moving an endpoint to another root collapses both endpoints there;
ordering never equates a parent child-index with a descendant's offset zero.
Point/node queries establish common-root membership before validating DOM
offsets, with distinct false/exception behavior for each API. Comparison modes
use the same strict ordering. `detach()` is inert and does not stop live
removal adjustment. The current active-range list retains ranges until Realm
retirement; it is not yet a weak live-range registry. Selection accepts only
ranges rooted in its current document. This is still bounded Range support:
shadow trees, editing algorithms, and
the full Web IDL interface surface remain separate work.

The native DOM begins at an Element; bootstrap publishes that Element's
canonical wrapper as a child of the Realm's Document, with a logical parent
back to the same Document. Synthetic doctypes use the same parent/child
relationship. Detached-document factories likewise pair child storage with
parent links. Range and Selection root checks must observe this shared DOM
topology, not invent their own document membership heuristic. A non-retaining
Realm-local Node brand covers native wrappers, synthetic nodes, and documents
so Range arguments cannot impersonate Nodes with a `nodeType` property.

The inline-style view in `runtime/css_style.js` is cached per Node wrapper.
`css_style_bindings.zig` resolves numeric handles through a narrow heap-stable
Host, borrows the Element only during the callback, and copies all returned
strings into Kiesel. JavaScript performs string/argument conversion; the native
ordered declaration owner supplies parsing, validation, priority, longhand
order, queries, serialization, and transactional mutations. The style pass
reads the same Element-owned block. CSSOM mutations use owned attribute storage,
style invalidation and render requests; SVG also invalidates its layout/paint.
Cloning copies pending shorthand data independently of attribute serialization.
See the [inline declaration ownership contract](document-and-rendering.md#document-module-ownership)
for raw attribute revisions and publication. The legacy whole `Node.style`
assignment still enters `style_set` to preserve its immediate transition-start
behavior; its raw replacement uses the shared native grammar on the next read.
Its background-color transitions copy absolute floating-point samples, including
an interrupted transition's current sample, into Element-owned color tracks.
No source strings or computed-field pointers survive in those tracks.

Computed readback flushes before resolving the target, even when only an
ancestor was dirty, so inherited variables and root-relative font sizes are
current. Custom values are copied from the Element's computed environment into
Kiesel strings; no environment-backed slice crosses the callback. Computed
views expose the registry's longhands through both CSS and camel-case names;
ordinary property lookup is ASCII case-insensitive and custom names keep case.
The native readback uses registry color metadata and `color.resolve` to copy
resolved RGB/RGBA colors, including the element's foreground for currentcolor.
Temporary serialization storage retires only after copying to Kiesel. Dirty
fields after a failed flush yield an empty string. Inline declarations keep
specified keywords, and held computed views read fresh fields on each access.
Remaining
CSSOM work includes additional property-specific grammars/serialization, complete
IDL/descriptors and mutation records, and persistent stylesheet/rule APIs.
Value tokenization/normalization and escaped custom-name identity use the shared
native declaration layer, including source-preserving custom values and EOF repair.

`runtime/css_style.js` also installs a fresh `CSS` namespace in each document
Realm. `supports` performs Web IDL argument-count/string conversion before the
native CSS binding evaluates the query. The two-argument form treats property
names as literal CSSOM strings and rejects embedded priority; the single-argument
form accepts a condition or an implicitly parenthesized declaration, including
`!important`. Both use `css_supports.zig`, with the same strict selector predicate
as `@supports`. Native query allocations are callback-local and only a boolean
returns to Kiesel. No Element resolution, style flush, DOM mutation, or render
request occurs. The namespace is capability detection, not a live stylesheet
or rule-object owner.

## JavaScript element geometry

`runtime/geometry.js` supplies `getBoundingClientRect`, `getClientRects`,
`offsetWidth`/`offsetHeight`, `offsetLeft`/`offsetTop`/`offsetParent`, and
`clientWidth`/`clientHeight`/`clientLeft`/`clientTop`, plus
DOMRectReadOnly/DOMRect/DOMRectList snapshot values.
Element scroll offsets/dimensions and immediate `scroll`, `scrollTo` and
`scrollBy` use the same callback. Requests and results contain only numbers;
absent axes preserve their offsets and non-finite inputs normalize to zero.
`geometry_bindings.zig` retains only a narrow Host embedded
in `Js`. Each WindowRealm has a synchronous geometry callback installed after
document creation and cleared on replacement or retirement, like computed
style readback. The callback receives a numeric Node handle, not a Node or
layout pointer, and a typed rectangle/offset/box-metrics query.

`browser/script_geometry.zig` validates the Frame generation, reconciles the
latest native viewport request, and brings ancestor/target Frames through
stylesheet, style, and required layout work on the serialized Tab worker. This
runs under JsLock and must not evaluate script, call a lock-taking Js API,
commit/present, or retain the callback's output. The existing frame layout path
also refreshes its coupled retained-paint and interaction products; this is
not yet a layout-only performance boundary. Ordinary composition/presentation
remains pending for the normal render task.

Only the stylesheet-specific resource pass may run here or in computed-style
readback. The general pass can load/evaluate iframe documents and would
re-enter JsLock. Parser-blocking scripts can measure the partial styled DOM;
their completion retires style subscribers and layout/display borrows before
the parser resumes moving child-array storage.

After the flush, the adapter resolves the handle again and queries clean
layout through `render/element_geometry.zig`. Detached nodes and elements
without boxes return empty geometry. Visibility-hidden boxes retain geometry.
Client rectangles use the owning Frame's CSS viewport, including authored zoom
and supported translations and subtracting ancestor/document scroll; fixed
boxes do not subtract document scroll. Offset dimensions ignore transforms and
remove the target's accumulated authored zoom. Neither API includes native
chrome or raster/accessibility scale. Temporary native results are copied to
Kiesel numbers before the callback buffer is freed; returned rectangle/list
objects never update when the DOM changes.

Client dimensions use the used padding box (border box minus used borders),
not authored width strings. Native single-line inputs instead expose their
content-box inline clip; textareas expose the padding box. Their client insets
come from the same used edges as painting, including box-sizing and CSS zoom.
Ordinary inline fragments have zero client metrics, including retained empty
and whitespace-only insertion points.
The root uses the current scrollbar-excluded viewport dimensions; document
insets are not viewport gutters. Element-local clipping does not invent a
scrollbar reservation where the renderer draws none. Offset positions use the
first fragment relative to the offset parent's padding edge, ignoring both
scrolling and transforms and removing the target's effective authored zoom.
Root/body and viewport-fixed boxes have no offset parent; positioned ancestors,
transform containers, static table ancestors, and effective-zoom boundaries
participate in parent selection. The selected Node is a synchronous borrow:
the adapter captures its handle with the non-lock-taking active-window helper,
then JavaScript uses the canonical wrapper cache. Detached/retired handles
produce zero metrics and a null parent without calling into a retired Frame.

Scroll requests synchronously flush style/layout before clamping to the used
range. Element offsets use the box's effective zoom; root HTML vertical offsets
map to the Frame viewport. A successful move refreshes sticky descendants,
marks the owning paint cache and schedules normal presentation, without
evaluating JavaScript inside the callback. Geometry reads refresh sticky offsets
before copying boxes, so script-visible rectangles and the next paint agree.
Horizontal root scrolling, RTL/reversed ranges, smooth scrolling, scroll events
and overflow-axis longhands remain separate capabilities.

This is an initial HTML box-geometry slice, not complete CSSOM View. Geometry
inherits layout's integer precision, bounded formatting, and translation-only
transform support. Decorated inline boxes and complex/vertical fragmentation,
SVG boxes, Range text rectangles, quirks-mode body viewport rules, themed
choice/select/button sizing, textarea editing/scrollbars and intrinsic rows/cols,
transformed fixed containing blocks, and additional scroll APIs need separate coverage.
Do not claim meaningful rendering benchmark scores from merely exposing the
property names: verify the layout work and supported workload first.

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
