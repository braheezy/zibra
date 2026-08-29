# Zibra agent guide

Zibra is a Zig browser built from
[Web Browser Engineering](https://browser.engineering). The tutorial is
complete; current work is bug fixes, optional exercises, compatibility, and
maintainability.

## Read in this order

1. This file for repository-wide rules.
2. The nearest `AGENTS.md` for the files being changed.
3. The relevant domain page in the
   [architecture index](docs/architecture-and-lifetimes.md) before changing an
   owner, thread boundary, navigation generation, DOM mutation, invalidation
   phase, JavaScript callback, URL/response lifetime, render snapshot, or
   shutdown order.
4. The [testing guide](docs/testing.md) when choosing verification.

Keep the nearest guide and authoritative domain document current when a change
alters commands, source layout, ownership, threading, testing, or subsystem
contracts. Nested guides should route and state local hazards; do not duplicate
an architecture document or fixture catalog in them.

## Map

| Area | Entry point |
| --- | --- |
| CLI and isolated inspection | `src/main.zig` |
| Interactive app/native windows | `src/browser/app.zig` |
| Per-window browser, tabs, chrome | `src/browser/` |
| Layout, display commands, effects | `src/browser/render/` |
| DOM, HTML, CSS, selectors | `src/document/` |
| Shared focusability policy | `src/document/focus.zig` |
| Kiesel host integration | `src/script/` |
| URLs, HTTP, cookies, caching | `src/network/` |
| Tasks and synchronization | `src/runtime/` |
| Shared low-level primitives | `src/core/` |
| Tutorial message-board server | `server.py` |
| Tests, goldens, fixtures | `tests/` |

## Working rules

- Keep ownership explicit. Do not shallow-copy an owning `Url`, response,
  command container, native handle, or resource-backed slice.
- Treat raw `*Node`, `*Frame`, layout, and JavaScript callback pointers as
  synchronous generation-bound borrows unless the architecture documentation
  explicitly gives them stable identity and retention.
- Keep files cohesive. Several thousand lines triggers a responsibility
  review; approaching 10,000 lines requires active decomposition before adding
  another distinct responsibility. Extract around a real data owner or
  subsystem boundary, not arbitrary line ranges, circular facade modules, or
  tiny indirection-only files.
- Use `//!` for a module's role and owner. Use `///` on public APIs to state
  ownership transfer, errors, thread/phase preconditions, or invariants that a
  caller must uphold. Inline comments should explain a non-obvious reason, not
  narrate the next statement; remove stale tutorial/history commentary once
  the corresponding contract is documented.
- Prefer isolated CLI diagnostics: `--dump-dom`, `--dump-style`,
  `--dump-layout`, and `--dump-display-list` stop at successive document
  phases; screenshot mode exercises software composition and raster.
- Do not edit `SDL.zig/` unless the task explicitly targets the local SDL
  binding dependency.
- Use `rg`/`rg --files` for repository searches. Preserve unrelated work in a
  dirty workspace.

## Verification

Use the narrowest relevant step while iterating:

- `zig build test-document`
- `zig build test-render`
- `zig build test-network`
- `zig build test-script`
- `zig build test-browser`

Before handoff, run the relevant broader checks:

- `zig build check` — portable aggregate;
- `zig build test-pipeline` — exact style/layout/display-list goldens,
  including box model and nested CSS zoom;
- `zig build test-screenshot` — native macOS visual goldens;
- `zig build test-server` — tutorial server behavior.

`test-docs` and `test-format` are also available independently. Report which
checks ran and which platform/manual checks remain. Put interactive regressions
in `tests/manual/` with a short `How to verify` comment and update its
[catalog](tests/manual/README.md).

## Working an issue

Use `gh issue view` to read the issue and linked book context. Closing an issue
requires complete behavior without a regression, plus unit/golden/manual
coverage appropriate to the pipeline stage. Do not treat a visible demo alone
as proof of the ownership, invalidation, or shutdown contract underneath it.
