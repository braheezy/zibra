This project is a Zig implementation of https://browser.engineering (the original is in Python). We built a browser from scratch, chapter by chapter, following the book’s core algorithms while adapting to the Zig codebase and supporting libraries.

Status

- The full tutorial book is implemented.
- From here on, we focus on bug fixes and implementing the book’s extra exercise features.

Build and Run

- Always run `zig build` after code changes.
- `zig build run` starts the browser with the blank default page.
- `zig build run -- <url>` starts the browser at a specific URL.

Third-Party Libraries (Special)

- z2d: 2D raster/compositor used for drawing display lists to surfaces and compositing effects like opacity. Core rendering paths flow through `src/browser/root.zig` and `src/browser/render/layout.zig`.
- kiesel: JavaScript engine/runtime used by `src/script/js.zig` to implement a minimal DOM/JS host environment.
- sdl2: Windowing/input/event loop and the primary platform integration for rendering.
- zigimg: Image decoding/handling for `<img>` and other image resources.

Architecture Map (High Level)

- Entry point: `src/main.zig` parses args and initializes `Browser`.
- Browser core: `src/browser/root.zig` owns window setup, event loop, tabs, rendering, and compositor integration.
- Tabs/Frames: `src/browser/tab.zig` manages navigation, DOM trees, CSS rules, layout, paint, hit-testing, and JS context per frame.
- HTML parser & DOM: `src/document/parser.zig` builds the DOM tree and applies computed styles.
- CSS parsing: `src/document/css_parser.zig` parses CSS rules; `src/document/selector.zig` matches tag/descendant selectors.
- Layout & paint: `src/browser/render/layout.zig` builds display lists, handles text/layout, and emits draw commands; `src/browser/render/font.zig` owns font and glyph resources.
- JS runtime/host bindings: `src/script/js.zig` implements `document`, events, `XMLHttpRequest`, timers, and `querySelectorAll`.
- Networking & URLs: `src/network/url.zig` handles URL parsing, request schemes, redirects, cookies, and response decoding.
- Chrome UI: `src/browser/chrome.zig` handles the address bar and browser controls.
- Runtime support: `src/runtime/` contains the task runner, synchronization wrapper, and timing utility.
- Shared primitives: `src/core/` contains low-level reusable state helpers.

Subsystem Guide (Where To Work)

- HTML parsing / DOM: `src/document/parser.zig`
- CSS parsing / selectors / cascade: `src/document/css_parser.zig`, `src/document/selector.zig`, `src/document/parser.zig` (style application)
- Layout, paint, display list: `src/browser/render/layout.zig`
- Font and glyph resources: `src/browser/render/font.zig`
- Rendering & compositor: `src/browser/root.zig`, `src/browser/render/layout.zig`
- JavaScript features: `src/script/js.zig`
- Requests, redirects, gzip, cookies, and file/data/about URLs: `src/network/url.zig`
- Tabs/frames/navigation: `src/browser/tab.zig`
- UI/chrome: `src/browser/chrome.zig`
- Tasking and synchronization: `src/runtime/task.zig`, `src/runtime/sync.zig`

For ownership and lifetime contracts, read `docs/architecture-and-lifetimes.md` before changing navigation, rendering, JavaScript callbacks, or task shutdown.

Verification Guidance (For Issues)

- Provide a minimal HTML test file that demonstrates the change. Put it under a clear path like `tests/manual/<issue-id>.html`.
- Include a short “how to verify” section at the top of the HTML file (as comments) describing the exact expected behavior and what to click/observe.
- Prefer deterministic, visible outcomes (text changes, color changes, layout changes) that can be confirmed by a human.
- If the feature is interactive (events, JS), include a simple on-page status area that updates on success.
- Run and verify with `zig build run -- /absolute/path/to/test.html`.
- Run `zig build test` for the unified unit-test suite.
- On macOS, run `zig build test-screenshot` for the native deterministic screenshot fixture.
- For screenshots, use the `zibra-screenshot` skill in `.agents/skills/zibra-screenshot`. Run setup once, then run capture to produce `out/screenshot/zibra.png`.
