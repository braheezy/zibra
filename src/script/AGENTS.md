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
- Detached/queued work must use the document generation contract from
  `src/browser/`; never retain a callback context or frame as a long-lived
  pointer.
- Preserve Kiesel's GC-root and `JsLock` assumptions. Do not add unlocked
  cross-thread host mutation without documenting and enforcing its owner.
- Attribute and inline-style mutation can affect `:has` matches. Dirty the
  changed element's style and its ancestor chain before requesting a render.
- Exercise interactive behavior with a deterministic `tests/manual/` page that
  reports success in-page.
