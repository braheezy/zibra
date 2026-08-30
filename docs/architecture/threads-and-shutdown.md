# Threads, tasking, SDL, and shutdown contracts

This document is authoritative for task ownership, worker boundaries,
synchronization, native-thread affinity, helper accounting, and teardown.
Read it before changing Browser/Tab scheduling, networking dispatch,
accessibility speech, raster work, SDL access, or shutdown.

## Thread roles

### Browser/UI thread

Interactive `BrowserApp` is the sole SDL event poller and text-input owner. It
routes each addressed event to a live Browser by native window ID, broadcasts
shared session generations, ticks windows, creates or removes windows, uploads
completed software surfaces, updates titles, and calls SDL presentation APIs.

It also rebuilds the Browser's private HTML chrome and snapshots committed page
and chrome command trees while `Browser.lock` stabilizes their borrowed leaf
resources. Input handlers should publish state or enqueue Tab work and return;
they must not synchronously perform slow raster work.

### Tab worker

Every Tab owns one named serialized `TaskRunner`. Navigation, parsing,
JavaScript, DOM mutation, style, layout, paint, focus, and most page input run
there. Queued work that can cross a document replacement carries a copied
`DocumentHandle` `(window_id, document_generation)`, not a `*Frame`, `*Node`,
or callback-context pointer.

### Raster-and-draw worker

Every Browser embeds one `presentation_worker.Worker`, which owns the named
raster runner, active/result state, worker-only software surfaces, compositor
cache, and their joined teardown. A job is a self-contained `RasterSnapshot`
plus scalar presentation state. It owns all recursive command containers and
copied leaf pixels, uses the SMP allocator, and never calls SDL. Pure z2d
command interpretation belongs to `software_renderer.Renderer`, which imports
neither Browser nor SDL. The worker may raster and assemble software surfaces
while the UI thread keeps handling input and the Tab worker builds a later
generation.

Completed results publish into the presentation owner under `Browser.lock`.
They carry only numeric tab identity; a dirty newer generation, identity/window
mismatch, or shutdown discards them. Accepted surface ownership moves to the UI
thread together with its allocator. Browser alone uploads it and presents.

### Networking worker

`BrowserSession` owns one heap-stable named networking runner. Ordinary Browser
fetches synchronously bridge through an embedded `resource_loader.Loader` that
borrows only the Browser allocator/I/O and shared session. A document's
complete linked-resource batch is one queued task; that task starts all
transport workers and joins them before returning so results remain in
source-order slots and no transport worker outlives its borrowed Loader or
batch storage.

Joined transport workers call the low-level synchronized transport directly.
They must not submit back to the same networking queue and deadlock behind the
coordinator waiting for them.

The browser-free inspection CLI is the deliberate direct-fetch exception.

### Accessibility worker

Each Tab owns one accessibility runner. A speech task owns a flattened copy of
reason, role, name, and permitted value bytes. It retains no Tab, DOM,
accessibility-node, or tree-string pointer. Turning the feature off clears
pending speech; an active backend call remains owned until shutdown joins it.

### Detached helpers

Timeout, interval, animation-deadline, and asynchronous XHR helpers are
accounted by their Tab. A helper context owns its arguments or borrows only
heap-stable owners protected by that accounting reference. Its last action
releases the reference. Tab shutdown wakes/cancels helpers where supported and
waits for the count to reach zero before retiring borrowed document, Browser,
mutex, or measurement state.

Async HTTP currently has no cancellation token, so shutdown can wait for
network I/O indefinitely. This is a responsiveness gap, not permission to
retire its owners early.

## Task contract

A queued `Task` owns its opaque context until exactly one cleanup callback
runs. That occurs after `run_fn`, when a queue is cleared, or immediately when
scheduling is rejected after shutdown. Cleanup is outside the task's trace
event.

Every task also carries:

- a borrowed stable trace name, normally a literal starting with `task:` and
  naming the operation rather than the payload type;
- an explicit semantic priority independent of that name.

Rendering and direct input are urgent, navigation/document work is normal, and
work originating from asynchronous JavaScript APIs is low. FIFO is preserved
within a rank. After eight higher-rank selections bypass lower work, one oldest
lower-priority task runs and the burst resets. Clearing the queue resets that
bookkeeping as well.

`TaskRunner.shutdown` is a quiescence boundary: publish quit, reject and clean
queued work, join the active worker, and only then release runner storage or
anything a task can borrow. Do not detach TaskRunner workers.

`TaskRunner.initNamed` borrows a stable worker label and `MeasureTime`. Stop the
runner before either label owner or measurement state retires.

## Thread batches

`runtime/thread_batch.zig` is a synchronous start-all/join-all boundary. Build
the complete caller-owned job/result slice before spawning. Every successfully
started thread must be joined before return. If native spawn fails, preserve
the operation's synchronous behavior for that slot. No job or result may
escape the call.

## Timers and animation deadlines

Animation deadlines use the monotonic `awake` clock and absolute timestamps.
A continuous chain advances from its prior deadline; an idle chain starts from
the current clock. The frame estimator smooths tab animation work and software
presentation work independently, uses the slower overlapping stage, adds
headroom, and rounds up to a 33ms cadence bucket. It reacts upward faster than
downward and resets when the active tab or successful root document changes.

Every helper and queued animation task carries a generation. Superseded work
must not publish state or clear a newer generation. The UI tick schedules the
next Tab animation before snapshotting the prior commit for raster so both
workers can overlap.

`setInterval` uses generation-stamped one-shot helpers, not one permanently
looping thread. After a live callback finishes, the JavaScript wrapper schedules
exactly one next delivery. The Tab cancellation key includes window,
document-generation, and JavaScript handle. `clearInterval`, navigation,
frame teardown, and shutdown remove the relevant keys; sleepers poll those keys
promptly and queued stale deliveries become no-ops. One-shot timeout callbacks
remove their registry entry before invocation.

## Locks and lock ordering

- `Browser.lock` stabilizes committed render/presentation state, dirty and
  animation generation state, optimistic/committed URL snapshots, pending tab
  creation, and raster result transfer. Never hold it during software raster,
  network round trips, JavaScript evaluation, or a native modal dialog.
- `TaskRunner.mutex` and its condition protect one queue and worker state.
- `BrowserSession.network_lock` protects cookie/cache lookup, copying,
  eviction, and mutation. Copy request headers and cached responses while
  locked; release it before transport.
- `BrowserSession.lock` protects visited/bookmark sets. Generations are atomic
  so BrowserApp can observe a change without retaining map storage.
- `JsLock` serializes evaluation and many host callbacks. Native callbacks
  entered while it is already held must use explicit lock-aware helpers.

BrowserApp must not hold a session mutex and a Browser lock simultaneously. It
samples atomic session generations, then visits one Browser at a time.

There is still no comprehensive Tab/DOM/Layout/FontManager mutex or owner-thread
assertion. Prefer immutable snapshots and a clear mutation thread over growing
one coarse lock across the page pipeline.

## SDL and graphics affinity

Only the Browser/UI thread may:

- poll SDL events or manage process text input;
- create/destroy or use renderer-bound windows, renderers, and textures;
- upload the software surface, copy it to the renderer, and present;
- change native titles or show native dialogs.

The raster worker performs z2d software work only. `FontManager` owns SDL_ttf
handles and mutable glyph caches; access must be serialized and all workers
that could borrow cached pixels must stop before fonts retire. BrowserApp keeps
one extra SDL_ttf reference until all window FontManagers close their paired
references.

Screenshot mode is windowless: it may initialize SDL video for SDL_ttf's macOS
requirement but creates no window, renderer, texture, or text-input owner. It
waits for Tab and accounted-helper quiescence, runs software composition, and
exports the root surface.

## Headless WPT sessions

A one-test WPT Session owns a standalone headless Browser and is heap-stable
for as long as a top-level WindowRealm can call its report sink. The creating
thread drives the ordinary nonblocking `Browser.tick` path. The Tab worker's
native report callback copies callback-scoped JSON into an SMP-allocated,
mutex-protected mailbox and returns; it must not tear down the Browser or join
its own TaskRunner. This is initially a pending candidate. The Session thread
may promote it only after the reporting Tab's active task has returned and its
current serialized queue is empty. The monotonic deadline takes precedence at
or after its timestamp and retires an undrained candidate as `TIMEOUT`. This
barrier follows the JavaScript host's outer-turn Promise-job checkpoint because
the Tab task remains active until that checkpoint returns. It does not prove
resource quiescence or correct native routing for jobs from another Realm in a
shared Agent.

After either terminal value, the creating thread follows ordinary standalone
Browser teardown and only then destroys the callback context. Semantic
completion never uses screenshot readiness, Browser idleness, a sleep, or
`process.exit`. Until navigation and HTTP helpers have complete cancellation
and transport-deadline coverage, the external runner retains a longer process
watchdog. A watchdog kill or missing valid record is an infrastructure failure,
not a semantic WPT `TIMEOUT`.

## Shutdown order

The enforced process order is:

1. publish Browser/Tab shutdown and reject new UI, Tab, and JavaScript work;
2. deinitialize each Browser presentation worker, which stops/joins its raster
   runner before releasing queued/completed results, surfaces, and caches;
3. wake timers, install the Kiesel host interrupt, and stop/join serialized Tab
   runners;
4. with the last speech producer stopped, clear and join each accessibility
   runner;
5. wait for all accounted helpers; their completion tasks are rejected and
   cleaned by the stopped Tab runner;
6. retire Browser render snapshots, then destroy Frame layout, DOM, scripts,
   and source owners;
7. destroy each Browser's page/chrome layouts, font caches, z2d state, texture,
   renderer, and window in reverse dependency order;
8. after the final Browser, stop/join the session networking runner, destroy
   HTTP/cookie/cache/session state, and finish shared measurement;
9. stop text input, release the App SDL_ttf guard, and quit SDL.

Tab's serialized runner stops before its accessibility runner because Tab work
is the speech producer. Both stop before their shared MeasureTime. BrowserApp
session and measurement state outlive every Browser and helper borrow.

Standalone Browser teardown follows the same dependencies but owns the final
session, measurement, SDL_ttf, and SDL steps itself. Constructors and partial
initialization must use reverse-order `errdefer` rollback matching normal
destruction.

## Review rules

Do not:

- detach a worker that retains owner pointers without accounting,
  cancellation, and an owner-side wait;
- use a generation embedded in an object that the helper can outlive;
- treat a short sleep, idle poll, process exit, or arena allocator as a join;
- destroy Browser, Tab, session, allocator, mutex, queue, or measurement state
  before every borrowing worker is joined;
- call SDL presentation APIs from a worker;
- add a lock to one field and infer that the complete object graph is safe.

Concurrency tests should force ordering with barriers/conditions and assert
cleanup/join behavior. Avoid timing-only sleeps as proof.
