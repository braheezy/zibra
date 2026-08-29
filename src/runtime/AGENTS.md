# Runtime subsystem guide

This directory owns the named task runners used by tabs and the networking
dispatcher, synchronization wrappers, and measurement support.

Read [threads and shutdown](../../docs/architecture/threads-and-shutdown.md)
before changing queues, thread lifetime, shutdown, helper accounting, task
priority, or trace ownership.

- A queued `Task` owns its opaque context until exactly one cleanup callback
  runs.
- Every `Task` carries a borrowed trace name that must remain alive until the
  task executes or is discarded. Use stable literals beginning with `task:`
  and name the user-visible operation, not its context struct. The runner
  brackets `run_fn` with that trace event; cleanup is outside the event.
- Every producer also assigns a semantic priority. Rendering and direct input
  are urgent, navigation/document work is normal, and callbacks originating in
  asynchronous JavaScript APIs are low. Preserve FIFO within a rank. After
  eight higher-rank selections bypass lower work, run one oldest lower-priority
  task; this bounded escape is the starvation guarantee, not wall-clock sleeps.
- Clearing a queue also resets its priority-burst bookkeeping. Rejected and
  discarded tasks retain the same exactly-once cleanup contract regardless of
  priority.
- `TaskRunner.shutdown` is a quiescence boundary: it rejects/cleans pending
  work and joins the worker. Do not reintroduce detached workers.
- `TaskRunner.initNamed` borrows a stable worker label for native thread naming
  and trace registration. BrowserSession uses one heap-stable runner named
  `Networking thread`; each Tab also owns a runner named `Accessibility thread`
  whose tasks own complete speech text. Both must stop before the shared
  `MeasureTime` they borrow. Stop the Tab's serialized producer before its
  accessibility runner so no new utterance can race speaker shutdown.
- `thread_batch.zig` is a synchronous join boundary for caller-owned job/result
  slots. Construct the complete slice before starting it; every native thread
  must be joined before return, and a spawn failure must retain correct
  synchronous behavior.
- Browser/Tab owners must remain alive until every worker and accounted helper
  that can borrow them has stopped.
- Add focused concurrency tests that force the ordering being changed; do not
  rely on sleeps or process exit as proof of safety. Run the consuming focused
  test and `zig build check`.
