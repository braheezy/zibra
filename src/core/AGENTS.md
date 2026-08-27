# Core subsystem guide

This directory contains reusable low-level primitives. Its current
`ProtectedField` invalidation graph is used by document style and layout.

Read [`../../docs/architecture-and-lifetimes.md`](../../docs/architecture-and-lifetimes.md)
before changing dependency registration or destruction behavior.

- Dependency maps retain raw subscriber pointers. A subscriber must be removed
  before its address becomes invalid. Supported structural DOM mutation uses a
  coarse pre-mutation clear of all style publishers and forces full style and
  layout recomputation; general per-edge unsubscription remains unresolved.
- `ProtectedField.lastValue` is an explicit non-subscribing historical read.
  It may be used while dirty only when the consumer needs the last published
  state, such as the visual baseline for an interrupted CSS transition; it is
  not a substitute for recomputation or a clean `get`.
- `Frame.document` uses field dirtiness as a phase guard as well as an
  invalidation signal. Its owning layout pointer may be read with `lastValue`
  only for ordered retirement; style must republish the field before layout or
  hit testing uses `get`.
- Keep core primitives independent of Browser, SDL, Kiesel, and URL layers.
- Changes here need direct unit coverage plus regression coverage in each
  consuming subsystem where the lifecycle can differ.
