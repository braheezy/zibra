# Core subsystem guide

This directory contains reusable low-level primitives. Its current
`ProtectedField` invalidation graph is used by document style and layout.

Read the
[invalidation contract](../../docs/architecture/document-and-rendering.md#protectedfield-and-style-invalidation)
and [risk registry](../../docs/architecture/risks-and-review.md) before changing
dependency registration or destruction behavior.

- Source-owned edges are indexed by the publisher and linked into the
  subscriber. Destruction unlinks either endpoint. Registered fields, including
  their reverse-list heads, must never move. Structural DOM mutation retains
  its coarse pre-mutation clear and full style/layout recomputation boundary.
- `ProtectedField(T)` is a comptime-generated inline value, not a heap object.
  Its dependency table is unmanaged: `init` is allocation-free, while
  `addDependency`/`read` receive the dependency source's allocator and
  `deinit` must receive that same allocator. Release builds erase diagnostic
  object/property names. Do not put a managed allocator back into every field
  or allocate merely to construct a clean dependency graph.
- `ProtectedField.lastValue` is an explicit non-subscribing historical read.
  It may be used while dirty only when the consumer needs the last published
  state, such as the visual baseline for an interrupted CSS transition; it is
  not a substitute for recomputation or a clean `get`.
- `Frame.document` uses field dirtiness as a phase guard as well as an
  invalidation signal. Its owning layout pointer may be read with `lastValue`
  only for ordered retirement; style must republish the field before layout or
  hit testing uses `get`.
- Keep core primitives independent of Browser, SDL, Kiesel, and URL layers.
- `relocatable_identity.zig` is the non-owning bidirectional map for values
  stored at addresses that may move. Its caller owns the pointees and issuer,
  reserves before a mutation, unpublishes old addresses, and rebinds the same
  scalar identities synchronously before a foreign callback can run. It must
  never grow document, JavaScript, or browser policy into this core boundary.
- `RelocationObserver` is the type-erased synchronous bridge for a second
  caller-owned identity registry. Its item argument is an opaque address key,
  not a dereferenceable borrow after storage growth; every returned token must
  be rebound or retired before control leaves the mutation transaction.
- Changes here need direct unit coverage plus regression coverage in each
  consuming subsystem where the lifecycle can differ. Run the relevant focused
  tests and `zig build verify`.
