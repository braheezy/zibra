# Script subsystem guide

`js.zig` is the host layer between Zibra's DOM and the Kiesel JavaScript
runtime. It implements windows, DOM handles, events, timers, XHR, and host
callbacks.

Read [`../../docs/architecture-and-lifetimes.md`](../../docs/architecture-and-lifetimes.md)
before changing callback registration, DOM handles, asynchronous completion,
or Kiesel allocation/locking.

- JavaScript node handles must not silently retarget after DOM mutation.
- Detached/queued work must use the document generation contract from
  `src/browser/`; never retain a callback context or frame as a long-lived
  pointer.
- Preserve Kiesel's GC-root and `JsLock` assumptions. Do not add unlocked
  cross-thread host mutation without documenting and enforcing its owner.
- Exercise interactive behavior with a deterministic `tests/manual/` page that
  reports success in-page.
