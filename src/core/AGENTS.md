# Core subsystem guide

This directory contains reusable low-level primitives. Its current
`ProtectedField` invalidation graph is used by document style and layout.

Read [`../../docs/architecture-and-lifetimes.md`](../../docs/architecture-and-lifetimes.md)
before changing dependency registration or destruction behavior.

- Dependency maps retain raw subscriber pointers. A subscriber must be removed
  before its address becomes invalid. Supported structural DOM mutation uses a
  coarse pre-mutation clear of all style publishers and forces full style and
  layout recomputation; general per-edge unsubscription remains unresolved.
- Keep core primitives independent of Browser, SDL, Kiesel, and URL layers.
- Changes here need direct unit coverage plus regression coverage in each
  consuming subsystem where the lifecycle can differ.
