This project is a Zig implementation of https://browser.engineering (the original is in Python). We built a browser from scratch, chapter by chapter, following the book’s core algorithms while adapting to the Zig codebase and supporting libraries.

Status

- The full tutorial book is implemented.
- From here on, we focus on bug fixes and implementing the book’s extra exercise features.

Build and Run

- Always run `zig build` after code changes.
- `zig build run` starts the browser with the blank default page.
- `zig build run -- <url>` starts the browser at a specific URL.

Third-Party Libraries (Special)

- z2d: 2D raster/compositor used for drawing display lists to surfaces and compositing effects like opacity. Core rendering paths flow through `src/browser.zig` and `src/Layout.zig`.
- kiesel: JavaScript engine/runtime used by `src/js.zig` to implement a minimal DOM/JS host environment.
- sdl2: Windowing/input/event loop and the primary platform integration for rendering.
- zigimg: Image decoding/handling for `<img>` and other image resources.

Architecture Map (High Level)

- Entry point: `src/main.zig` parses args and initializes `Browser`.
- Browser core: `src/browser.zig` owns window setup, event loop, tabs, rendering, and compositor integration.
- Tabs/Frames: `src/tab.zig` manages navigation, DOM trees, CSS rules, layout, paint, hit-testing, and JS context per frame.
- HTML parser & DOM: `src/parser.zig` builds the DOM tree and applies computed styles.
- CSS parsing: `src/cssParser.zig` parses CSS rules; `src/selector.zig` matches tag/descendant selectors.
- Layout & paint: `src/Layout.zig` builds display lists, handles text/layout, and emits draw commands.
- JS runtime/host bindings: `src/js.zig` implements `document`, events, `XMLHttpRequest`, timers, and `querySelectorAll`.
- Networking & URLs: `src/url.zig` handles URL parsing/schemes and request logic.
- Chrome UI: `src/chrome.zig` handles the address bar and browser controls.
- SDL bindings: `src/sdl.zig` wraps SDL usage for window/input.

Subsystem Guide (Where To Work)

- HTML parsing / DOM: `src/parser.zig`
- CSS parsing / selectors / cascade: `src/cssParser.zig`, `src/selector.zig`, `src/parser.zig` (style application)
- Layout, paint, display list: `src/Layout.zig`
- Rendering & compositor: `src/browser.zig`, `src/Layout.zig`
- JavaScript features: `src/js.zig`
- Requests, caching, redirects, gzip, file/data URLs: `src/url.zig`, `src/cache.zig`
- Tabs/frames/navigation: `src/tab.zig`
- UI/chrome: `src/chrome.zig`

Verification Guidance (For Issues)

- Provide a minimal HTML test file that demonstrates the change. Put it under a clear path like `tests/manual/<issue-id>.html`.
- Include a short “how to verify” section at the top of the HTML file (as comments) describing the exact expected behavior and what to click/observe.
- Prefer deterministic, visible outcomes (text changes, color changes, layout changes) that can be confirmed by a human.
- If the feature is interactive (events, JS), include a simple on-page status area that updates on success.
- Run and verify with `zig build run -- /absolute/path/to/test.html`.
- For screenshots, use the `zibra-screenshot` skill in `.agents/skills/zibra-screenshot`. Run setup once, then run capture to produce `out/screenshot/zibra.png`.
