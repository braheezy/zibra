# Task 01 - JavaScript Animations

Section: JavaScript Animations
Depends on: none

Goal: support JS-driven style changes so requestAnimationFrame demos can update opacity.

Tasks:
- [x] Add a `Node.prototype.style` setter in the JS runtime that calls a native `style_set(handle, value)`.
- [x] Implement a native `style_set` handler in `src/js.zig` that looks up the node by handle and updates its `style` attribute string.
- [x] Mark the active tab as needing a render when `style_set` runs (schedule an animation frame if needed).
- [ ] Plumb the native `style_set` callback through the JS render context (similar to existing `innerHTML` or XHR hooks).
- [ ] Verify a JS opacity animation updates each frame without errors (`zig build run`).
