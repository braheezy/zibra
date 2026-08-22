# Runtime subsystem guide

This directory owns the per-tab task runner, synchronization wrappers, and
measurement support.

Read [`../../docs/architecture-and-lifetimes.md`](../../docs/architecture-and-lifetimes.md)
before changing queues, thread lifetime, shutdown, or helper accounting.

- A queued `Task` owns its opaque context until exactly one cleanup callback
  runs.
- Every `Task` carries a borrowed trace name that must remain alive until the
  task executes or is discarded. Use stable literals beginning with `task:`
  and name the user-visible operation, not its context struct. The runner
  brackets `run_fn` with that trace event; cleanup is outside the event.
- `TaskRunner.shutdown` is a quiescence boundary: it rejects/cleans pending
  work and joins the worker. Do not reintroduce detached workers.
- Browser/Tab owners must remain alive until every worker and accounted helper
  that can borrow them has stopped.
- Add focused concurrency tests that force the ordering being changed; do not
  rely on sleeps or process exit as proof of safety.
