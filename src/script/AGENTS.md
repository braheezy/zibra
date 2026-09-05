# Script subsystem guide

`js.zig` is the owning host boundary between Zibra and Kiesel. Focused modules
beside it implement DOM identity and mutation transactions, transition
parsing, and native binding domains without importing the coordinator.

Read [JavaScript and accessibility contracts](../../docs/architecture/javascript-and-accessibility.md)
before changing this directory. Structural mutation and retained layout
borrows are documented in
[document and rendering](../../docs/architecture/document-and-rendering.md);
queued work and shutdown are documented in
[threads and shutdown](../../docs/architecture/threads-and-shutdown.md).

## Source map

- `js.zig` owns the Agent, its neutral host Realm, heap-stable per-document
  `WindowRealm` owners, callback registries, active-window switching,
  evaluation, and public locked entry points.
- `runtime/bootstrap.js` defines the page-visible DOM, traversal, event, timer,
  canvas, XHR, cookie, and messaging shims over `__native`; Zig loads it with
  `@embedFile` before evaluating page code.
- `runtime/css_style.js` supplies cached live inline-style declarations over
  the Node wrapper's attribute APIs. It preserves unrelated declarations and
  custom-property case; native computed-style readback flushes pending ancestor
  style work and copies values before returning to Kiesel.
- `dom_handles.zig` owns the two-way Node pointer/numeric identity maps for one
  window generation.
- `dom_tree_bindings.zig` owns read-only document lookup and authored Node
  topology bindings. It receives a callback-scoped root/handle/issuer borrow,
  never imports `Js`, and returns only copied strings or numeric snapshots.
- `dom_mutation.zig` owns synchronous child-array transfer transactions and
  receives only borrowed identity stores plus paired invalidation hooks.
- `inline_event.zig` identifies authored `on<event>` source and builds the
  Realm-local invocation expression; it owns neither DOM storage nor Kiesel
  execution.
- `event_focus_bindings.zig`, `canvas_bindings.zig`,
  `timer_bindings.zig`, `network_bindings.zig`, and
  `document_write_bindings.zig` validate their native APIs
  and call heap-stable narrow host interfaces embedded in `Js`.
  Network parent-window calls are same-origin-only and limited to the
  compatibility `notify(string)` callback; they do not expose parent DOM.
- `wpt_bindings.zig` exposes only a bootstrap-time enablement check and a
  synchronous serialized-result sink. It neither owns WPT session state nor
  decides browser deadlines, process health, or manifest expectations.
- `native_bindings.zig` installs comptime binding tables; `transitions.zig`
  parses and starts typed DOM transitions.

## Local contracts

- Preserve Kiesel's traced allocation, GC-root, and `JsLock` assumptions. A
  native callback entered with the lock held uses lock-aware helpers; do not
  add an unlocked cross-thread host mutation.
- Each outer Browser-to-JavaScript turn drains the Agent Promise-job queue to
  a fixed point before its active-window guard and `JsLock` are released.
  Evaluation, lifecycle/inline/browser event delivery, postMessage, timers,
  animation frames, and XHR are outer turns; native callbacks that re-enter
  event or parent-window helpers are not and must defer the checkpoint to
  their caller. Preserve contained page exceptions and surface the Agent's
  uncatchable host-interrupt flag after draining.
- One same-origin Agent can own multiple WindowRealms. Kiesel switches its
  execution Realm for each queued job, but Zibra does not yet switch
  `current_window_id` with it; do not treat Promise jobs that cross those
  windows as correctly routed native calls. Kiesel's default rejection tracker
  is also inert, so draining jobs does not yet report unhandled rejections.
- Kiesel retains pointers to the binding-domain `Host` interfaces. Keep those
  interfaces embedded in the heap-stable `Js` allocation, synchronous, and
  narrower than the coordinator. A returned Node or Element is a callback-
  scoped borrow and must never be queued.
- Each non-null document installation receives a fresh `WindowRealm`; the
  preceding realm is retired and null-root invalidation leaves its host maps
  inert. WindowRealms own handle maps, listener/timer registries, named
  globals, detached roots, and source buffers retained by detached DOMParser
  trees. Node wrappers must never silently retarget
  after child-array relocation, address reuse, or document replacement.
- A WindowRealm can temporarily carry one type-erased Node relocation observer
  for a stack-bound live parser. Install it only immediately around direct
  parser-blocking evaluation and clear it before parser control yields or the
  Frame can retire; mutation code may receive old addresses only as opaque
  identity-map keys and must not dereference them.
- `Js.nodeHandleRelocationObserver` exposes the inverse, Realm-owned observer
  for parser-originated child-array moves. It rebinds only already-published
  JavaScript handles, borrows the live WindowRealm, and must be removed from a
  parser before that Realm retires. A removed subtree may retain JavaScript
  wrappers as a detached root while its parser pins are retired: parser pins
  describe the active document tree, not detached-node retention.
- Browser lifecycle delivery calls `Js.dispatchLifecycleEvent` only for an
  already initialized live Realm. Missing or retired realms are inert no-ops,
  never an excuse to allocate a replacement Realm. `document.readyState`
  reads a narrow synchronous browser callback when installed; its context is
  generation-bound and must be cleared before Frame retirement. Lifecycle
  listeners run against document/window targets in the document Realm, and a
  page exception must not abort later lifecycle listeners or the load phase.
- Browser-owned `Js.dispatchInlineEvent` dispatches authored handlers such as
  `<body onload>` to a Node wrapper with ordinary `this`, `target`, and
  `currentTarget` semantics. It may initialize an existing live Realm for a
  document with no ordinary script, but never creates one for stale work; a
  handler exception is contained and must not block lifecycle completion.
- `document.write` crosses only the synchronous parser-active callback seam.
  Its temporary bytes must be copied into Frame-owned HTML source before the
  native call returns; clear the callback before parser control yields. A
  missing sink is intentionally inert and must not silently implement
  `document.open()` or retain a parser pointer.
- A WPT report callback belongs to one live document Realm. Install it after
  non-null `setNodes` creates that Realm and before the first evaluation
  bootstraps it; bootstrap checks enablement only once. Keep its context alive
  until completion or Realm retirement, and reinstall it for every replacement
  document. Null-root invalidation and replacement clear the callback.
- WPT reporting runs synchronously under `JsLock`. The JSON slice is temporary,
  so the receiver may only copy it into its own result owner and signal that
  owner; it must not retain the slice, re-enter `Js`, touch DOM/Frame state, or
  block teardown. The first bridge is top-level and result-only; see the
  architecture document for unsupported diagnostics and completion semantics.
- HTML fragments parsed for `innerHTML` are not document-parser input. Mark
  every script in such a fragment inert before installing its child storage;
  resource refresh must not turn serialized or newly parsed fragment scripts
  into deferred executable scripts. Explicitly created-and-attached script
  Elements remain eligible for the ordinary dynamic-resource path.
- The active-window guard restores the prior host window id after every public
  entry point. Do not leave a page realm or window id installed across a
  callback, task boundary, navigation, or shutdown path.
- Synchronous DOM mutation validates and stages before invalidation, retires or
  rebinds every affected handle and optional relocation token, and invokes the
  paired completion callback only after storage, parents, and identities are
  final. Network/resource loading is deferred until the host call returns.
- Detached roots are heap-stable owners. `appendChild`, `insertBefore`,
  `removeChild`, and `replaceChildren` transfer ownership rather than
  shallow-copying a subtree.
- Null-root invalidation may run outside the Kiesel-owning Tab worker. It makes
  wrappers inert by clearing native maps and does not call into JavaScript.
- Bootstrap owns one Node-wrapper cache per document Realm. Every host-returned
  numeric Node identity must pass through that cache so query, traversal,
  events, named IDs, canvas, and mutation results compare by object identity.
  Selector results are static `NodeList` snapshots; `Node.childNodes` is a
  cached live `NodeList` refreshed at the JavaScript mutation boundaries.
  `HTMLCollection` is a Realm-local live Proxy view over fresh native
  snapshots. The current `attributes` records remain lightweight snapshots
  until native Attr identity and ordering are complete. These views expose
  authored children only and never generated pseudo boxes.
- Asynchronous callbacks carry copied generation-stamped document handles and
  own every URL, message, policy, body, and string they retain. Never queue a
  Frame, Node, or `JsRenderContext` pointer.
- Strings returned to JavaScript from serialization, DOM topology, cookies,
  XHR, or messages move into Kiesel's traced allocator before temporary or
  source-backed native storage retires.
- Event dispatch snapshots numeric handles target-to-root. Keep `target`
  stable, update `currentTarget`, and keep propagation control separate from
  default prevention.
- Browser-generated focus/blur events are target-only. `focus()` transfers a
  handle, forces current layout, and re-resolves after blur listeners before
  installing state.
- Timer registries are scoped by window/document generation. A live interval
  schedules one next one-shot after its callback; clearing or navigation makes
  sleepers/queued deliveries no-ops.
- Canvas wrappers are scoped by window and stable Node handle. Pixel commands
  dirty retained paint; path/state-only commands do not. Unsupported z2d
  methods return `error.NotImplemented` and are exposed as nonfatal
  `undefined`.
- Range boundary points are synchronous Realm borrows. Detached fragments and
  comments are JavaScript-owned; extraction transfers fully selected native
  nodes and uses `setNodeData` only for text splitting.

`js.zig` remains large because it owns the realm/window lifecycle and several
DOM bindings. Continue extracting cohesive binding domains behind narrow host
interfaces. Do not create a cycle where helpers import or receive the complete
`Js` coordinator, and do not replace ownership with forwarding-only façades.

## Verification

Run `zig build test-script` while iterating and the relevant
`test-document`/`test-browser` step for DOM or callback integration. Run
`zig build verify` before handoff. Add a deterministic in-page result and update
the [manual fixture catalog](../../tests/manual/README.md) for interactive
JavaScript behavior.
