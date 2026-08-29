# Architecture and lifetime contracts

This page is the entry point for Zibra's architecture documentation. It keeps
the reading path short while the linked domain documents hold the authoritative
details.

Before changing a boundary, read this index, the nearest `AGENTS.md`, and only
the domain documents relevant to the change.

## Domain documents

| Document | Read before changing |
| --- | --- |
| [Architecture overview](architecture/overview.md) | Source responsibilities, principal owners, allocator domains, or inspection-pipeline boundaries |
| [Document and rendering](architecture/document-and-rendering.md) | DOM storage, source buffers, structural mutation, `ProtectedField`, style/layout invalidation, retained paint, display lists, raster snapshots, compositing, or hit testing |
| [Threads and shutdown](architecture/threads-and-shutdown.md) | Task runners, helper threads, locks, networking dispatch, raster/accessibility workers, SDL affinity, partial initialization, or teardown |
| [Navigation and network](architecture/navigation-and-network.md) | URL/response ownership, document replacement, iframe loading/history, styles/scripts/images, redirects, cache, cookies, CORS, CSP, Referer, X-Frame-Options, or certificate UI |
| [JavaScript and accessibility](architecture/javascript-and-accessibility.md) | Kiesel roots/locking, WindowContexts, Node handles, DOM APIs, events, timers, XHR callbacks, postMessage, focus, accessibility, or canvas bindings |
| [Risks and review](architecture/risks-and-review.md) | Any ownership or cross-thread review; unresolved gaps, forbidden patterns, and the lifetime checklist live here |
| [Testing guide](testing.md) | Choosing focused, portable, native visual, and manual verification |

## Non-negotiable invariants

- An owning `Url`, response, command container, image/surface, native handle,
  or resource-backed slice is moved or cloned explicitly; never shallow-copy it
  into two apparent owners.
- A raw `*Node`, `*Frame`, layout pointer, or JavaScript callback context is a
  synchronous generation-bound borrow unless a domain document explicitly
  defines a stable identity and retention boundary.
- DOM/layout/display consumers retire before the source objects and buffers
  they borrow.
- Structural DOM mutation synchronously retires or rebinds every affected
  handle, pointer, callback, interaction index, invalidation edge, and render
  snapshot before child storage can move.
- Worker payloads own their data or borrow heap-stable owners covered by an
  accounting/join boundary. Stop and join workers before those owners,
  allocators, locks, queues, or measurement state retire.
- Raster workers use self-contained snapshots and do not call SDL. Native
  event, renderer, texture, dialog, title, and presentation operations remain
  on the Browser/UI thread.
- A generation mismatch prevents stale work from publishing; it does not make
  the stale work's borrowed memory safe by itself.
- A process arena, short sleep, idle poll, or process exit is not lifetime
  verification. Exercise ownership-sensitive code with reclaiming allocators
  and forced ordering where practical.

## High-level destruction direction

```text
queued/worker consumers
  -> Browser render snapshots and compositor state
  -> Frame display lists and copied interaction indexes
  -> layout and invalidation graph
  -> DOM and Element-owned resources
  -> stylesheet/HTML source buffers and owning URLs
  -> Browser native resources
  -> shared session, measurement, SDL_ttf guard, and SDL
```

Construction proceeds from stable owners toward borrowers. Teardown proceeds
in the direction above. Consult the domain documents for exceptions and the
precise join points.

## Keeping these documents useful

- Put a contract in one authoritative domain document. Nested `AGENTS.md`
  files should route to it and contain only local rules or hazards.
- Update documentation when a source owner, thread boundary, invalidation
  phase, command, or verification contract changes.
- Describe ownership, phase preconditions, error behavior, and the reason for
  a non-obvious invariant. Do not preserve a feature-by-feature implementation
  diary here.
- When an unresolved risk becomes enforced by a type, snapshot, assertion, or
  join, update the risk registry and name the enforcement point.
