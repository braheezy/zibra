# Manual regression fixture catalog

These pages cover interaction, timing, networking, and visual behavior that is
not fully represented by portable automated checks. The primary page must
contain a short `How to verify` comment and expose a deterministic visible
result. Child frames, navigation targets, stylesheets, scripts, images, and
server helpers are support files and are normally opened through the primary
page.

This catalog states intent; it does not claim that a page was automatically
run or passed. See [`docs/testing.md`](../../docs/testing.md) for verification
tiers and baseline policy.

## Parsing, CSS, layout, and invalidation

| Primary fixture | Contract exercised |
| --- | --- |
| [`acid1-box-model.html`](acid1-box-model.html) | Acid1-inspired nested box spacing, borders, backgrounds, and visual compatibility baseline |
| [`dump-pipeline.html`](dump-pipeline.html) | Shared style, layout, and display-list inspection input |
| [`dump-dom.html`](dump-dom.html) | Isolated HTML parser/DOM dump input |
| [`anonymous-block-boxes.html`](anonymous-block-boxes.html) | Anonymous inline/block grouping |
| [`block-dimensions.html`](block-dimensions.html) | CSS block width/height and surrounding box edges |
| [`border-geometry.html`](border-geometry.html) | Asymmetric mitered solid-border joins and zero-content border triangles |
| [`display.html`](display.html) | Computed display classification and anonymous runs |
| [`css-tables.html`](css-tables.html) | Bounded table/table-row/table-cell grid tracks, anonymous direct cells, and row-height stretch |
| [`inline-stylesheet.html`](inline-stylesheet.html) | Inline/linked stylesheet DOM order, hidden style content, and shared inspection stages |
| [`links-bar.html`](links-bar.html) | User-agent class selector styling for repeated navigation bars |
| [`table-of-contents.html`](table-of-contents.html) | User-agent ID selector and generated table-of-contents bar styling |
| [`float-clear.html`](float-clear.html) | Float exclusion, clearing, and formatting-context containment |
| [`float-paint-phases.html`](float-paint-phases.html) | Normal block backgrounds below floats, inline wrapping, and overflow formatting-context avoidance |
| [`paint-order-phases.html`](paint-order-phases.html) | Negative positioned, normal block background, float, inline content, positioned auto/zero, and positive z-index paint/hit phases |
| [`margin-collapse.html`](margin-collapse.html) | Adjoining sibling/empty-block margin struts and clearance barriers around floats |
| [`issue-60-line-breaks.html`](issue-60-line-breaks.html) | Line-breaking regression from issue 60 |
| [`list-bullets.html`](list-bullets.html) | `display:list-item`, marker paint, and indentation |
| [`run-in-headings.html`](run-in-headings.html) | Run-in heading/layout behavior |
| [`relative-lengths.html`](relative-lengths.html) | Relative CSS length resolution |
| [`positioned-offsets.html`](positioned-offsets.html) | Relative visual offsets and absolute positioning without flow growth |
| [`fixed-positioning.html`](fixed-positioning.html) | Viewport containing block, scroll-stable paint, and post-scroll input hit testing |
| [`z-index.html`](z-index.html) | Positioned signed z-index, stable ties, nested paint/hit order |
| [`alternate-text-direction.html`](alternate-text-direction.html) | Basic directed line alignment |
| [`centered-title.html`](centered-title.html) | Multiline title centering |
| [`preformatted.html`](preformatted.html) | Scoped whitespace/newline preservation and monospace selection |
| [`soft-hyphens.html`](soft-hyphens.html) | Discretionary break selection and suffix transfer |
| [`superscript.html`](superscript.html) | Scoped superscript sizing and baseline placement |
| [`small-caps.html`](small-caps.html) | Scoped small-caps glyph selection |
| [`font-family.html`](font-family.html) | Inherited family selection and platform fallback |
| [`font-line-height.html`](font-line-height.html) | Nested used line height |
| [`font-shorthand.html`](font-shorthand.html) | Font shorthand expansion/reset and longhand interaction |
| [`important.html`](important.html) | Declaration-local `!important` cascade |
| [`css-declaration-recovery.html`](css-declaration-recovery.html) | Escaped declaration delimiters, comment whitespace, and invalid-value cascade recovery |
| [`selector-sequences.html`](selector-sequences.html) | Concatenated tag/class/ID selectors and specificity |
| [`generated-pseudo-elements.html`](generated-pseudo-elements.html) | Private `:before`/`::after` generated boxes, before/authored/after layout order, and DOM-child transparency |
| [`has-selectors.html`](has-selectors.html) | Strict-descendant `:has` matching and recomputation |
| [`style-descendant-invalidation.html`](style-descendant-invalidation.html) | Dirty ancestor path traversal while clean sibling subtrees are skipped |
| [`paint-invalidation.html`](paint-invalidation.html) | Retained display-list mutation and clean sibling reuse |
| [`protected-layout-phases.html`](protected-layout-phases.html) | Protected style/layout phases versus paint/compositor-only animation |
| [`window-resize.html`](window-resize.html) | Horizontal/vertical native resize, viewport invalidation, and rerender |
| [`max-width-media.html`](max-width-media.html) | Inclusive max-width query under page zoom and native resize |
| [`width-media-iframes.html`](width-media-iframes.html) | Exact iframe media width and parent-driven viewport changes |
| [`css-zoom.html`](css-zoom.html) | Authored subtree zoom composed with accessibility zoom, frames, focus, and hit testing |

## DOM, JavaScript, forms, and dynamic resources

| Primary fixture | Contract exercised |
| --- | --- |
| [`form-enter.html`](form-enter.html) | Return-key form submit and out-of-form input behavior |
| [`form-get.html`](form-get.html) | GET form encoding in the query with no POST body |
| [`checkboxes.html`](checkboxes.html) | Attribute-backed toggle state and successful-control encoding |
| [`new-input-types.html`](new-input-types.html) | Hidden layout/focus suppression and password masking with real submission value |
| [`node-children.html`](node-children.html) | Fresh immediate Element-only `Node.children` arrays |
| [`create-element.html`](create-element.html) | `createElement`, detached ownership, append, and insert-before ordering |
| [`matching-children.html`](matching-children.html) | Append-only retained block-layout child matching |
| [`invalidating-previous.html`](invalidating-previous.html) | Middle insertion with retained owners and protected predecessor invalidation |
| [`remove-child.html`](remove-child.html) | Attached-to-detached transfer, handle stability, and reattachment |
| [`replace-children.html`](replace-children.html) | Atomic emptying, detached observable children, focus and iframe retirement |
| [`replace-children-transfer.html`](replace-children-transfer.html) | Multi-source transfer order, identity, source collapse, and iframe rebinding |
| [`id-globals.html`](id-globals.html) | ID globals across source, rename, detach, reattach, and innerHTML mutation |
| [`event-bubbling.html`](event-bubbling.html) | Target-to-root delivery, stopPropagation, preventDefault, and ordinary elements |
| [`html-serialization.html`](html-serialization.html) | Live inner/outer HTML, current attributes, escaping, and void elements |
| [`dynamic-resources.html`](dynamic-resources.html) | Script/style insertion and stylesheet removal through structural mutation |
| [`document-cookie.html`](document-cookie.html) | Native cookie getter/setter, parameters, and HttpOnly visibility boundary |
| [`cookie-expiration.html`](cookie-expiration.html) | Replaced expiration deadlines and immediate deletion by past dates |
| [`cors.html`](cors.html) | Cross-origin XHR wildcard opt-in versus fetched-but-hidden response |
| [`referrer-policy.html`](referrer-policy.html) | Default, no-referrer, and same-origin Referer behavior |
| [`post-message-target-origin.html`](post-message-target-origin.html) | Exact, wildcard, and mismatched cross-origin postMessage delivery |
| [`canvas-2d.html`](canvas-2d.html) | Canvas sizing, retained context identity, drawing/state, reset, and graceful unsupported methods |
| [`script-iframes.html`](script-iframes.html) | Dynamic iframe load, replacement, unload, focus removal, and fresh context creation |

## Navigation, history, frames, session, and security

| Primary fixture | Contract exercised |
| --- | --- |
| [`visited-links.html`](visited-links.html) | Session visited state and repaint after Back |
| [`bookmarks.html`](bookmarks.html) | Chrome bookmark toggle and generated `about:bookmarks` list |
| [`history-forward.html`](history-forward.html) | Forward/back document chronology and target helpers |
| [`fragments.html`](fragments.html) | Same-document fragment history and layout-derived targets |
| [`middle-click.html`](middle-click.html) | Owning link transfer into a new tab and source visited repaint |
| [`resubmit-requests.html`](resubmit-requests.html) | POST history confirmation, cancel, and retained-body replay |
| [`iframe-history.html`](iframe-history.html) | Joint history across sibling and nested frames |
| [`multi-frame-focus.html`](multi-frame-focus.html) | Tab/Shift-Tab traversal across nested, sibling, and empty frames |
| [`x-frame-options.html`](x-frame-options.html) | DENY, same-origin SAMEORIGIN, and unrestricted top-level navigation |
| [`certificate-errors.html`](certificate-errors.html) | Verified HTTPS lock, owned warning page, and no bypass |
| [`view-source.html`](view-source.html) | View-source URL ownership and presentation |
| [`window-title.html`](window-title.html) | DOM title copying and native title updates |
| [`multiple-windows.html`](multiple-windows.html) | Addressed native windows with independent UI state and shared session metadata |

## Input, hit testing, focus, and accessibility

| Primary fixture | Contract exercised |
| --- | --- |
| [`address-bar-cursor.html`](address-bar-cursor.html) | Clamped cursor movement, insertion, and Backspace |
| [`focus-blur.html`](focus-blur.html) | Content/chrome blur handoff and one visible cursor |
| [`focus-ring-contrast.html`](focus-ring-contrast.html) | Two-tone focus ring on light and dark backgrounds |
| [`focus-visible.html`](focus-visible.html) | Pointer/keyboard focus modality and `:focus-visible` |
| [`mixed-inline-focus.html`](mixed-inline-focus.html) | Wrapped nested-inline focus rectangles versus one block rectangle |
| [`focus-method-events.html`](focus-method-events.html) | Script focusability, target-only focus/blur, refreshed geometry, and chrome blur |
| [`display-list-hit-testing.html`](display-list-hit-testing.html) | Topmost painted fragments, transforms, rounded clips, overlap, and iframe routing |
| [`layout-local-hit-testing.html`](layout-local-hit-testing.html) | Parent-local transformed/scrolled/clipped traversal |
| [`rounded-hit-testing.html`](rounded-hit-testing.html) | Rounded-corner misses for blocks, rich buttons, and text inputs |
| [`hover.html`](hover.html) | Deferred `:hover`, ancestor matching, clearing, and layout-changing hover |
| [`rich-buttons.html`](rich-buttons.html) | Contained arbitrary children, height growth, nested interactions, and parser recovery |
| [`html-chrome.html`](html-chrome.html) | HTML-based chrome controls, tab links, editing, and stable viewport boundary |
| [`mouse-wheel-scroll.html`](mouse-wheel-scroll.html) | Immediate wheel scrolling and clamping |
| [`scrollbar.html`](scrollbar.html) | Scroll range and native scrollbar-thumb geometry |
| [`overflow-scroll.html`](overflow-scroll.html) | Focused nested element scrolling, clipping, and boundary fallback |
| [`overflow-hidden.html`](overflow-hidden.html) | Non-scrolling descendant clipping and clipped hit targets |
| [`animated-scroll.html`](animated-scroll.html) | Smooth body scrolling, retargeting, immediate paths, and reduced motion |
| [`touch-input.html`](touch-input.html) | Multitouch taps, drag cancellation, synthetic-event deduplication, and chrome activation |
| [`accessibility-read-highlight.html`](accessibility-read-highlight.html) | Incremental spoken-node highlighting |
| [`threaded-accessibility.html`](threaded-accessibility.html) | Nonblocking ordered speech snapshots and cancellation |
| [`forced-colors.html`](forced-colors.html) | High-contrast palette, semantic state, and forced-colors media query |

## Images, effects, compositing, and animation

| Primary fixture | Contract exercised |
| --- | --- |
| [`background-images.html`](background-images.html) | Post-cascade loading, size modes, source crop, and rounded clipping |
| [`fixed-background.html`](fixed-background.html) | Viewport-phased fixed background tiles clipped by moving element boxes |
| [`object-fit.html`](object-fit.html) | Fill, contain, and fractional cover crop within a replaced box |
| [`lazy-loading.html`](lazy-loading.html) | Eager/near/far requests and post-decode layout change without refetch |
| [`aspect-ratio.html`](aspect-ratio.html) | Derived image/iframe axes and lazy fallback-to-natural ratio |
| [`image-placeholders.html`](image-placeholders.html) | Zero/one-axis placeholders, reflow, and alt-dependent broken icon |
| [`blur-filter.html`](blur-filter.html) | Blur order with clipping, opacity, and translation |
| [`interest-region.html`](interest-region.html) | Bounded four-window-height raster cache across long-page scrolling/resizing |
| [`background-color-transition.html`](background-color-transition.html) | RGBA interpolation and deterministic terminal state |
| [`easing-functions.html`](easing-functions.html) | Default ease and keyword timing differences |
| [`composited-animations.html`](composited-animations.html) | Simultaneous opacity/translation and draw-only scrolling |
| [`width-height-animations.html`](width-height-animations.html) | Layout-inducing dimensions and continuous line reflow |
| [`css-animations.html`](css-animations.html) | Named keyframes, alternate cycles, composited opacity, and width relayout |
| [`transform-animation-overlap.html`](transform-animation-overlap.html) | Animated-transform assume-overlap barrier and stable paint order |
| [`sparse-composited-layers.html`](sparse-composited-layers.html) | Surface-area merge budget for distant compatible chunks |
| [`short-composited-layers.html`](short-composited-layers.html) | Direct short-command planes versus surface-backed glyph planes |
| [`opacity-plus-draw.html`](opacity-plus-draw.html) | Folded ancestor alpha on one composited-layer draw |

## Scheduling, loading, raster, and shutdown

| Primary fixture | Contract exercised |
| --- | --- |
| [`set-interval-cadence.html`](set-interval-cadence.html) | Multiple interval cadences under animation/render load and prompt cancellation |
| [`frame-clock-cadence.html`](frame-clock-cadence.html) | Absolute RAF deadlines, estimator buckets, and tab/raster overlap |
| [`task-scheduler.html`](task-scheduler.html) | Rendering priority and bounded starvation under timeout load |
| [`threaded-loading.html`](threaded-loading.html) | Parallel fetch with source-order script/style consumption and networking traces |
| [`raster-draw-thread.html`](raster-draw-thread.html) | Input responsiveness during expensive raster and UI-thread SDL presentation |
| [`lifecycle-long-timeout.html`](lifecycle-long-timeout.html) | Long helper cancellation and prompt shutdown |

## Screenshot support pages

`native-screenshot.html`, `emoji.html`, and several parsing/layout pages above
are also inputs to native screenshot goldens. Consult `build.zig` for the
authoritative automated screenshot set. Exact pixels can vary with platform
fonts, so pair portable semantic assertions with native goldens when possible.

## Serving fixtures

Pages involving cookies, requests, redirects, CORS, Referer, image request
logging, or X-Frame-Options must be served over the deterministic local server
described by their `How to verify` comment. `threaded-loading.html` uses
`threaded-loading-server.py` so equal-latency resources visibly overlap while
consumption remains in source order.
