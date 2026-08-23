# Script subsystem guide

`js.zig` is the host layer between Zibra's DOM and the Kiesel JavaScript
runtime. It implements windows, DOM handles, events, timers, XHR, and host
callbacks.

Read [`../../docs/architecture-and-lifetimes.md`](../../docs/architecture-and-lifetimes.md)
before changing callback registration, DOM handles, asynchronous completion,
or Kiesel allocation/locking.

- JavaScript node handles must not silently retarget after DOM mutation.
- `Node.children` is a fresh JavaScript array on each access. It wraps handles
  for immediate element children in DOM order, excludes text and deeper
  descendants, and relies on the existing handle invalidation boundary when a
  structural mutation retires child storage.
- `document.createElement` returns a window-owned, heap-stable detached Node.
  `appendChild` and `insertBefore` transfer only such detached roots into a
  child array, rebind handles for every relocated immediate child, and invoke
  the synchronous DOM-mutation boundary before attached storage can move.
- `removeChild` performs the inverse transfer: it accepts only a direct child,
  moves that subtree into a heap-stable window-owned detached root, preserves
  subtree handles, and rebinds siblings shifted in the attached child array.
- Element IDs are exposed as named globals for only the active window. The
  first duplicate ID in document order wins; empty IDs and names colliding
  with existing globals are skipped. Refresh the per-window registry whenever
  attached structure or an attached element's `id` changes, clearing old
  wrappers before any DOM pointer can move or disappear.
- `Node.id` reflects the live `id` attribute. `innerHTML` reads serialize the
  current children while writes retain the structural-mutation boundary;
  `outerHTML` reads include the element itself. Serialized buffers passed to
  Kiesel must use its traced allocator because ASCII String construction can
  retain the supplied bytes.
- `document.cookie` is a native accessor resolved through the active window's
  synchronous document callback. Getter results must move into Kiesel's traced
  allocator before temporary callback storage is freed, because ASCII String
  construction may retain the supplied bytes. Callback invalidation follows
  the same document-generation boundary as XHR and DOM callbacks.
- XHR same-origin/CORS policy belongs to the browser callback, not the
  JavaScript shim. A synchronous denied response surfaces as the existing
  cross-origin exception; asynchronous denial intentionally has no `onload`
  delivery because this exercise does not yet expose an `onerror` event. Both
  synchronous responseText and asynchronous onload delivery copy callback-owned
  bytes into Kiesel's traced heap before their native buffers are released.
- DOM listeners are scoped by window and a dispatched event follows a
  snapshotted target-to-root handle path. Reuse one Event while bubbling,
  update `currentTarget` for each node, keep `target` fixed, let
  `stopPropagation` finish the current node's listeners before stopping, and
  keep propagation control independent from `preventDefault`.
- Structural JavaScript mutation also clears current style-field subscriber
  maps while every endpoint is alive; the mandatory full style/layout render
  rebuilds dependencies after mutation.
- Null-root invalidation may run outside the Kiesel-owning tab worker. It must
  make wrappers inert by clearing native handle maps without calling back into
  JavaScript; a later non-null root install clears and rebuilds the registry on
  the worker before evaluation resumes.
- Detached/queued work must use the document generation contract from
  `src/browser/`; never retain a callback context or frame as a long-lived
  pointer.
- Preserve Kiesel's GC-root and `JsLock` assumptions. Do not add unlocked
  cross-thread host mutation without documenting and enforcing its owner.
- Timer handles and callback registries are scoped by JavaScript window ID.
  `setInterval` reuses the generation-stamped one-shot native timer boundary:
  after a live callback completes, its JavaScript wrapper schedules exactly one
  next delivery at the same delay. `clearInterval` removes both the JavaScript
  callback entry and the Tab's native generation-stamped cancellation key;
  sleeping helpers poll that key and already-queued deliveries become no-ops.
  Reset both registries when installing a replacement document; timeout
  callbacks are one-shot entries and must be removed before invocation. Keep
  timer JavaScript serialized on the tab worker.
- Attribute and inline-style mutation can affect `:has` matches. Dirty the
  changed element's style and its ancestor chain before requesting a render.
- Inline `style` replacement detects supported transitions from the previous
  computed value to the new declaration. Opacity creates a numeric transition;
  `background-color` parses both endpoints into RGBA and creates a color
  transition; `transform` accepts `none` and `translate(...)` and interpolates
  both axes. Split comma-separated transition lists only at top level so the
  commas inside `cubic-bezier(...)` remain part of one timing function. An
  omitted timing function means CSS `ease`; `linear`, `ease-in`, `ease-out`,
  `ease-in-out`, and valid explicit `cubic-bezier(...)` values are retained by
  value with the animation. Never retain slices from the temporary inline-style
  parse map.
- Exercise interactive behavior with a deterministic `tests/manual/` page that
  reports success in-page.
