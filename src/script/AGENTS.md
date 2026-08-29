# Script subsystem guide

`js.zig` is the host boundary between Zibra and Kiesel. It owns JavaScript
window contexts, DOM wrappers, events, timers, XHR, messaging, canvas wrappers,
and synchronous host callbacks.

Read [JavaScript and accessibility contracts](../../docs/architecture/javascript-and-accessibility.md)
before changing this directory. Structural mutation and retained layout
borrows are documented in
[document and rendering](../../docs/architecture/document-and-rendering.md);
queued work and shutdown are documented in
[threads and shutdown](../../docs/architecture/threads-and-shutdown.md).

## Local contracts

- Preserve Kiesel's traced allocation, GC-root, and `JsLock` assumptions. A
  native callback entered with the lock held uses lock-aware helpers; do not
  add an unlocked cross-thread host mutation.
- WindowContexts own handle maps, listener/timer registries, named globals, and
  detached roots. Node wrappers must never silently retarget after child-array
  relocation or address reuse.
- Synchronous DOM mutation validates and stages before invalidation, retires or
  rebinds every affected handle, and invokes the paired completion callback
  only after storage, parents, and handles are final. Network/resource loading
  is deferred until the host call returns.
- Detached roots are heap-stable owners. `appendChild`, `insertBefore`,
  `removeChild`, and `replaceChildren` transfer ownership rather than
  shallow-copying a subtree.
- Null-root invalidation may run outside the Kiesel-owning Tab worker. It makes
  wrappers inert by clearing native maps and does not call into JavaScript.
- Asynchronous callbacks carry copied generation-stamped document handles and
  own every URL, message, policy, body, and string they retain. Never queue a
  Frame, Node, or `JsRenderContext` pointer.
- Strings returned to JavaScript from serialization, cookies, XHR, or messages
  move into Kiesel's traced allocator before temporary native storage retires.
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

`js.zig` is already far beyond a cohesive module size. New binding domains
should become focused modules behind a narrow host interface. Prefer extracting
pure DOM-transfer planning or self-contained binding state first; do not create
a cycle where every helper imports or receives the complete `Js` coordinator.

## Verification

Run `zig build test-script` while iterating and the relevant
`test-document`/`test-browser` step for DOM or callback integration. Run
`zig build check` before handoff. Add a deterministic in-page result and update
the [manual fixture catalog](../../tests/manual/README.md) for interactive
JavaScript behavior.
