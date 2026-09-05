# Lifetime risks and review checklist

This registry distinguishes confirmed structural gaps from hypotheses. A
generation check, mutex, arena allocator, idle poll, or process exit is not by
itself proof that a borrowed pointer remains alive.

Definitions used throughout the architecture documents:

- **owns**: must release an allocation or native resource;
- **borrows**: may use a value only while a named owner remains live and
  address-stable;
- **moves**: transfers the single release responsibility;
- **snapshot**: data handed across a phase/thread boundary and retained until
  the consumer explicitly retires it;
- **confirmed risk**: the ownership gap is visible in source, whether or not a
  crash has been reproduced;
- **hypothesis**: a plausible consequence still requiring a focused
  reproducer, sanitizer report, or forced interleaving.

## Confirmed unresolved risks

### DOM identity is address-unstable

Children are values in resizable arrays while layout, focus, hover, iframe,
accessibility, display provenance, and JavaScript maps retain `*Node` values.
Supported structural APIs enter a synchronous retirement/rebind boundary, but
the representation does not make arbitrary future mutation safe. Prefer stable
node allocation or `(document_generation, node_id)` identity over expanding
the set of persistent raw pointers.

### Browser display clones still borrow leaf resources

Browser command clones own recursive containers, while image/glyph pixels,
DOM/effect identity, and layer pointers remain borrowed. Supported replacement
paths synchronously retire that state, and raster snapshots deep-copy worker
leaves, but the Browser clone is not independent by type. Either make all
leaves owned/reference-counted or retain the producing generation explicitly.

### Page Layout and FontManager lack one asserted mutation thread

Chrome has a private UI-only widget/font/display state and raster uses copied
leaves,
but interactive page input and resizing can still reach page layout/font state
while Tab work uses it. There is no complete lock or owner-thread assertion.

### URL and response ownership is conventional

`Url` is logically move-only but freely shallow-copyable by Zig. Response-body
ownership is inferred from scheme. Explicit clone/free discipline exists, but
the types cannot prevent two apparent owners or freeing a borrow. Tagged owners
remain desirable.

### JavaScript host mutation has a partial lock contract

Evaluation and many callbacks use `JsLock`; some callback setters and parent
realm operations do not. Their safety may depend on serialized ownership, but
that rule is not asserted at the API boundary.

### Async HTTP cannot be cancelled

XHR helpers retain owners safely and are included in shutdown accounting, but
a blocked operation can delay shutdown without a deadline or cancellation
token.

### Main-thread page readers lack a complete snapshot

Some input/accessibility paths can observe Frame state while the Tab worker
rebuilds it. `Browser.lock` covers committed render state, not the complete
DOM/layout/accessibility graph.

## Resolved foundations not to regress

- `TaskRunner.shutdown` rejects and cleans queued work exactly once and joins
  its active worker.
- Queued and detached document work carries copied generation-stamped handles,
  not Frame pointers.
- Navigation invalidates JS callbacks and destroys layout before DOM, DOM
  before source text, while URL/referrer owners remain alive through fetch.
- Browser render state retires in dependency order under `Browser.lock` before
  supported navigation, mutation, replacement, and shutdown.
- `Url.clone` builds independent Ada and data-URL owners.
- Timers poll cancellation, Kiesel polls a host interrupt, and Tab shutdown
  waits for accounted helpers.
- Stylesheet source text, rules, and keyframes stage and transfer as one
  generation.
- Accessibility diffing keeps prior tree strings alive until diff completion.
- Structural DOM APIs retire or synchronously rebind affected handles and
  pointer borrowers before storage moves.
- Dynamic iframe completion validates numeric markers, rebinds survivors, and
  stops removed child contexts before JavaScript resumes.
- Raster worker snapshots copy every leaf they use and call no SDL APIs.
- `ProtectedField` source-owned bidirectional edges unlink during either
  endpoint's destruction. Registered fields must remain address-stable;
  relocation still requires the structural clear/rebind boundary.

## Hypotheses needing focused tests

Do not cite these as root causes without evidence:

- a Browser display list observes retired image bytes or DOM identity after an
  unsupported mutation path;
- accessibility input races a worker rebuild and sees a retired tree;
- concurrent page layout/font access corrupts SDL_ttf or a glyph map;
- an arena-backed run hides a defect exposed immediately by a reclaiming
  allocator.

Useful forced tests include navigation while XHR is active, subtree mutation
after exporting handles, repeated incremental layout destruction, forced
Kiesel GC, image replacement while render state is retained, and shutdown
during every worker/helper phase.

## Forbidden patterns

Until stronger types enforce the contracts, do not:

- detach a thread retaining owner pointers without accounting, cancellation,
  and a shutdown wait;
- use a generation field embedded in an object the work can outlive;
- free source text while DOM, CSS, style, layout, or display values borrow it;
- retain `*Node` across a sibling-array mutation without synchronous
  invalidation/rebinding;
- mutate a subtree without retiring handles, focus/hover/hit/accessibility
  state, layout callbacks, and render snapshots;
- shallow-copy an owning URL, response, display container, image, surface,
  native handle, or texture and allow both copies to appear owning;
- move a value after storing a pointer to its own fields unless the pointee is
  independently heap-stable;
- retain a string or pixel slice without naming and retaining its owner;
- register a raw dependency without accounting for endpoint teardown;
- call renderer-bound SDL APIs outside the UI thread;
- destroy owners, allocators, locks, queues, or measurement before all borrowing
  workers are joined;
- infer safety from a short sleep, idle poll, generation mismatch, production
  arena, process exit, or one field-level mutex.

## Lifetime review checklist

- [ ] Every allocation and native handle has exactly one named owner.
- [ ] Every borrowed pointer/slice names its owner and the event ending the
      borrow.
- [ ] Owning values are moved or cloned explicitly.
- [ ] Structural mutation preserves stable identity or invalidates/rebinds
      every exported pointer, handle, callback, and index synchronously.
- [ ] Source text outlives every parsed slice.
- [ ] Stylesheet rules, keyframes, and source buffers move as one generation.
- [ ] Invalidation dependencies are removed or their publishers are cleared
      before an endpoint retires.
- [ ] Async work owns arguments or borrows only stable, retained storage.
- [ ] Cancellation state outlives every helper reading it.
- [ ] Threads are joined before owners, allocators, locks, queues, and
      measurement retire.
- [ ] Cross-thread operations have an asserted owner, immutable snapshot, or
      scoped lock.
- [ ] Render state independently owns leaves or explicitly retains the
      producing generation.
- [ ] JavaScript handles cannot resolve to another Node after mutation.
- [ ] Kiesel values reachable from host state have an intentional GC root.
- [ ] URL and response ownership is explicit at every call boundary.
- [ ] SDL resources are used on permitted threads and destroyed in reverse
      dependency order.
- [ ] Partial initialization has matching reverse-order rollback.
- [ ] Ownership-sensitive paths run under a reclaiming allocator where
      practical.
- [ ] Tests force navigation/mutation/shutdown while relevant async work is
      active.

## Cleanup priorities

1. Define and assert mutation threads for DOM, page Layout/FontManager, and SDL
   objects.
2. Introduce stable DOM identity and centralize mutation invalidation.
3. Make Browser render generations self-contained or explicitly retained.
4. Encode response ownership and add HTTP cancellation/deadlines.
5. Add forced-interleaving tests and debug assertions for every chosen
   contract.

When a type, join, assertion, or snapshot enforces an item, move it from the
risk list to the resolved foundation and identify the enforcement point.
