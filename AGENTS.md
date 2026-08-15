# Zibra agent guide

Zibra is a Zig browser built by following
[Web Browser Engineering](https://browser.engineering). The tutorial is
complete; current work is bug fixes and the book's optional exercises.

## Read in this order

1. This file for repository-wide rules.
2. The nearest `AGENTS.md` to the files being changed. Nested guides add the
   most specific rules for their subsystem.
3. [`docs/architecture-and-lifetimes.md`](docs/architecture-and-lifetimes.md)
   before changing navigation, rendering, JavaScript callbacks, URL ownership,
   or task shutdown.

Keep the nearest `AGENTS.md` and its linked documentation current whenever a
change alters commands, source layout, ownership, thread boundaries, testing,
or subsystem contracts. Add a focused nested `AGENTS.md` when a directory
becomes a distinct subsystem; do not turn this root guide into a second
architecture document.

## Map

| Area                                   | Entry point     |
| -------------------------------------- | --------------- |
| CLI and isolated inspection modes      | `src/main.zig`  |
| Browser, tabs, compositor, chrome      | `src/browser/`  |
| DOM, HTML, CSS, selectors              | `src/document/` |
| Kiesel host integration                | `src/script/`   |
| URLs, HTTP, cookies, caching, decoding | `src/network/`  |
| Tasking and synchronization            | `src/runtime/`  |
| Shared low-level primitives            | `src/core/`     |
| Fixtures and regression tests          | `tests/`        |

## Working rules

- Keep ownership explicit. Do not shallow-copy an owning `Url`, response,
  display-list container, native handle, or resource-backed slice.
- Treat raw `*Node`, `*Frame`, and JavaScript callback pointers as synchronous
  borrows unless the lifecycle documentation explicitly gives them a stable
  identity or lifetime.
- Prefer isolated CLI diagnostics when debugging a pipeline stage:
  `--dump-dom` stops after HTML parsing; `--dump-style` stops after computed
  styles; `--dump-layout` stops after geometry; `--dump-display-list` stops
  after paint-command generation. Screenshot mode exercises the full rendering
  pipeline.
- Do not edit `SDL.zig/` unless the task explicitly targets the local SDL
  binding dependency.

## Verification

- Run `zig build` after Zig or build-script changes.
- Run `zig build test` for unit coverage.
- Run `zig build test-dump-dom` for the isolated DOM CLI contract.
- Exercise `tests/manual/dump-pipeline.html` with the style, layout, and
  display-list commands when changing document-pipeline diagnostics.
- On macOS, run `zig build test-screenshot` for the windowless software-rendering fixtures.
- Put human-facing regressions in `tests/manual/` with a short verification
  comment. Use the `zibra-screenshot` skill for Linux/Xvfb captures when a
  screenshot is required.


## Doing an Issue

There are many GitHub issues tracking extra Exercises from the book. They are related by chapter and exercise number. Each contains a link to the browser engineering book chapter on the content, with the full context of the exercises near the bottom

To close an issue, the behavior described must be fully implemented without degrading the browser in other regards. Tests, including fixture html and golden comparisons, should be considered if appropriate. Unit tests are always appraciated.

Use the `gh` cli to fetch information about an issue.
