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

- `js.zig` owns the Agent, lock, realms, window contexts, callback registries,
  active-window switching, evaluation, and public locked entry points.
- `runtime/bootstrap.js` defines the page-visible DOM, event, timer, canvas,
  XHR, cookie, and messaging shims over `__native`; Zig loads it with
  `@embedFile` before evaluating page code.
- `dom_handles.zig` owns the two-way Node pointer/numeric identity maps for one
  window generation.
- `dom_mutation.zig` owns synchronous child-array transfer transactions and
  receives only borrowed identity stores plus paired invalidation hooks.
- `event_focus_bindings.zig`, `canvas_bindings.zig`,
  `timer_bindings.zig`, and `network_bindings.zig` validate their native APIs
  and call heap-stable narrow host interfaces embedded in `Js`.
- `native_bindings.zig` installs comptime binding tables; `transitions.zig`
  parses and starts typed DOM transitions.

## Local contracts

- Preserve Kiesel's traced allocation, GC-root, and `JsLock` assumptions. A
  native callback entered with the lock held uses lock-aware helpers; do not
  add an unlocked cross-thread host mutation.
- Kiesel retains pointers to the binding-domain `Host` interfaces. Keep those
  interfaces embedded in the heap-stable `Js` allocation, synchronous, and
  narrower than the coordinator. A returned Node or Element is a callback-
  scoped borrow and must never be queued.
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

`js.zig` remains large because it owns the realm/window lifecycle and several
DOM bindings. Continue extracting cohesive binding domains behind narrow host
interfaces. Do not create a cycle where helpers import or receive the complete
`Js` coordinator, and do not replace ownership with forwarding-only façades.

## Verification

Run `zig build test-script` while iterating and the relevant
`test-document`/`test-browser` step for DOM or callback integration. Run
`zig build check` before handoff. Add a deterministic in-page result and update
the [manual fixture catalog](../../tests/manual/README.md) for interactive
JavaScript behavior.
