# Test and fixture guide

`tests/manual/` contains minimal human-readable regression pages. Put a short
"How to verify" comment at the top of each page and make the expected result
visible and deterministic.

`tests/golden/` contains committed deterministic outputs. Update a golden only
after confirming that the behavioral change is intentional; do not use a golden
update to hide a regression.

Current checks:

- `zig build test` — unified Zig unit suite. The test artifact links SDL and
  SDL_ttf so browser-input tests can exercise real frame activation paths.
- `zig build test-dump-dom` — isolated HTML parse/DOM-dump output, including
  literal `about:blank`, malformed-navigation recovery, and unsupported-scheme
  recovery.
- `zig build test-screenshot` — windowless macOS software-rendering output,
  including the inherited alternate-text-direction, multiline centered-title,
  and scoped superscript, small-caps, and preformatted-text fixtures, plus
  discretionary soft-hyphen wrapping.
- `python3 -m unittest tests/test_server_message_board.py` — pure tutorial
  server routing, topic creation, authorization, escaping, message isolation,
  restart persistence, schema rejection, and failed-write rollback without
  binding a network port.

`tests/manual/visited-links.html` is the session-state regression: its self
link is purple initially, and its target becomes purple after visiting it and
returning with Back.

`tests/manual/bookmarks.html` exercises the chrome bookmark toggle and the
generated `about:bookmarks` link list. The selected button is yellow, and the
entry must disappear after toggling the page off and revisiting the list.

`tests/manual/address-bar-cursor.html` exercises clamped Left/Right movement,
insertion at the address cursor, and Backspace deletion before it.

`tests/manual/form-enter.html` verifies that Return in a focused text entry
dispatches the containing form's submit event, while an input outside a form
does not submit.

`tests/manual/form-get.html` and its target fixture verify over a localhost
server that GET submission puts encoded controls in the URL query and sends no
POST body.

`tests/manual/focus-blur.html` verifies that moving focus between content and
the address bar leaves exactly one visible cursor and clears the old focused
input styling.

`tests/manual/multi-frame-focus.html` and its child fixtures verify that Tab
and Shift-Tab exhaust each document, skip an iframe with no focusable content,
cross nested and sibling frame boundaries, and wrap only after the complete
frame tree.

`tests/manual/focus-ring-contrast.html` places focusable inputs on white and
black panels. The same 4px-white/2px-black two-tone ring must remain visible on
both backgrounds and follow keyboard focus without leaving a stale ring.

`tests/manual/focus-visible.html` distinguishes modality from DOM focus: a
clicked outside-form button has no native or author focus-visible indicator,
keyboard-focused links/buttons have both, and a clicked or tabbed input keeps
both. Its colored author rules also verify dynamic `:focus-visible` matching.

`tests/manual/mixed-inline-focus.html` checks focus geometry rather than ring
color: nested inline descendants merge into one rectangle per wrapped line,
while a multiline block with `tabindex` receives one rectangle around the
whole block.

`tests/manual/focus-method-events.html` verifies script focusability,
target-only focus/blur event order, synchronous layout before focus scrolling,
and address-bar blur when JavaScript returns focus to page content.

`tests/manual/accessibility-read-highlight.html` verifies that F3 enables the
screen-reader mode and each F4/read-page step speaks and highlights the same
accessibility node, including non-focusable content.

`tests/manual/threaded-accessibility.html` keeps animation and input visible
while a deliberately long node is spoken. It checks that speech does not block
UI work, copied utterances remain ordered, and disabling the screen reader
cancels speech that has not started.

`tests/manual/max-width-media.html` crosses an inclusive 500-CSS-pixel
`max-width` query using page zoom and native resize; the visible text and panel
change from red to green while the query is active.

`tests/manual/width-media-iframes.html` and its child fixture distinguish the
root CSS viewport from an iframe's exact `width` query. Page zoom activates a
parent rule that changes the iframe from 420px to 300px; the child must switch
its retained stylesheet generation in both directions on the follow-up frame.

`tests/manual/post-message-target-origin.html` and its port-8001 child fixture
send a mismatched, exact, and wildcard cross-origin message. Only the latter
two may reach the port-8000 parent, and the delivered event origin must name
the sending iframe's origin.

`tests/manual/css-zoom.html` and its child-frame fixture compare unzoomed,
2x, and nested 3x subtrees. Fixed boxes, fonts, controls, rounded geometry,
iframe contents, focus, and clicks must share the same authored scale, which
then composes multiplicatively with the browser's accessibility zoom.

`tests/manual/forced-colors.html` toggles F6 across deliberately low-contrast
author paint, semantic link/control states, and the `forced-colors` media
feature. Active CSS paint must use only the black/white/cyan/yellow palette.

`tests/manual/checkboxes.html` verifies checked and unchecked painting, click
toggles, omission of unchecked controls, explicit values, and the default
checked value `on` through a localhost GET submission.

`tests/manual/new-input-types.html` verifies that hidden inputs occupy no
layout or focus space, password values paint as stars, and both control types
retain their real values for form submission.

`tests/manual/certificate-errors.html` links to valid and invalid HTTPS
endpoints to verify committed-page padlocks, owned certificate warning pages,
and the absence of a proceed-anyway path.

`tests/manual/document-cookie.html` verifies the native JavaScript cookie
getter/setter and retained parameter serialization when served from localhost;
unit coverage supplies server-originated HttpOnly entries and proves they are
still request-visible but script-hidden and script-immutable.

`tests/manual/cookie-expiration.html` verifies that a future absolute Expires
date remains script-visible and that replacing it with a past date deletes the
cookie immediately. The tutorial message-board tests cover matching server-side
deadlines, sliding renewal, and stale-session cleanup.

`tests/manual/cors.html` uses different localhost ports for its page and XHR
server. It verifies wildcard opt-in exposes a cross-origin response while the
same server's headerless endpoint is fetched but remains unreadable.

`tests/manual/referrer-policy.html` links to tutorial-server probes for the
default Referer behavior plus `no-referrer` and `same-origin`. Use `localhost`
for the source so the `127.0.0.1` target is a distinct origin.

`tests/manual/rich-buttons.html` verifies inline rich-button containment,
block-driven height growth, independently targetable input/link descendants,
and nested-button parser recovery.

`tests/manual/html-chrome.html` verifies the browser-owned HTML chrome: button
actions, input editing, anchor-based tab selection, history-state styling, and
the stable page/chrome boundary.

`tests/manual/node-children.html` verifies that JavaScript `Node.children`
returns immediate elements in source order, skips interleaved text, excludes
deeper descendants, and produces a visible in-page result.

`tests/manual/create-element.html` builds and orders new elements without HTML
parsing, covering `document.createElement`, `appendChild`, `insertBefore`, and
the `null` reference append case with a visible in-page result.

`tests/manual/remove-child.html` removes an attached subtree into detached
ownership, verifies its nested and shifted-sibling handles, and reattaches the
same Node object under a different parent with a visible in-page result.

`tests/manual/id-globals.html` verifies source and dynamically added element
IDs as JavaScript globals, including `innerHTML`, rename, detach, reattach, and
non-identifier access through `window[...]`.

`tests/manual/event-bubbling.html` verifies painted ordinary-element click
targets, target-to-root listener order, same-node listener completion after
`stopPropagation`, and ancestor `preventDefault` cancellation of link
navigation.

`tests/manual/html-serialization.html` verifies live `innerHTML` and
`outerHTML`, reflected `id` mutation, attribute escaping, nested markup, and
void-element serialization with a visible in-page result.

`tests/manual/dynamic-resources.html` verifies that `innerHTML`-inserted scripts
and linked stylesheets are processed, and that removing an attached stylesheet
link retires its rules without undoing already-evaluated JavaScript.

`tests/manual/resubmit-requests.html` uses the tutorial server's deterministic
POST login to verify that Back to a POST target asks before replaying, Cancel
does not navigate, and Resubmit sends the retained body again.

`tests/manual/display-list-hit-testing.html` exercises painted-fragment,
translation, rounded-clip, overlap, and iframe click routing. Only the visible
topmost painted target should activate; its child and destination pages are
support fixtures in the same directory.

`tests/manual/rounded-hit-testing.html` isolates rounded-corner targeting for
ordinary blocks, rich buttons, and text inputs. Corner clicks leave the visible
counters unchanged while clicks in painted centers increment exactly one.

`tests/manual/layout-local-hit-testing.html` exercises parent-local traversal
through nested translations, reverse-order overlapping siblings, and clipped
element scrolling. Its visible counters distinguish the visual target from an
element's old untransformed or unscrolled box.

`tests/manual/z-index.html` exercises positioned signed z-index ordering,
stable DOM-order ties, the static-position gate, and recursive nested sibling
stacking. Visible counters verify that reverse hit testing follows paint order.

`tests/manual/animated-scroll.html` exercises body `scroll-behavior`, smooth
Up/Down motion, repeated-key retargeting, the immediate `auto`/wheel path, and
the reduced-motion override. `tests/manual/composited-animations.html` also
combines smooth scrolling with simultaneous opacity/transform animation.

`tests/manual/interest-region.html` is a deliberately long, color-banded page
for crossing and reversing over tab raster-cache boundaries. Scrolling and
resizing must remain continuous while the cached surface stays bounded to four
native window heights.

`tests/manual/overflow-scroll.html` exercises fixed-height `overflow: scroll`
boxes, click-to-focus arrow scrolling, clipping, and innermost-to-outer nested
scroll fallback before the root page moves.

`tests/manual/blur-filter.html` exercises subtree blur together with rounded
overflow clipping, group opacity, and translation. Its display-list dump also
keeps the filter wrapper's serialized contract pointer-free.

`tests/manual/multiple-windows.html` exercises nonrepeating Ctrl+N native-window
creation, per-window tab/chrome/focus/scroll state, addressed close behavior,
and process-shared bookmark/visited state.

`tests/manual/touch-input.html` exercises single and simultaneous touch taps,
drag cancellation, synthetic-mouse de-duplication, link cancellation, and
touch activation of browser chrome on a touch-capable display.

`tests/manual/set-interval-cadence.html` records min/average/max spacing for
16, 50, and 125ms intervals while requestAnimationFrame repeatedly forces
style, layout, and paint work. It must reach a stable DONE state after all
three callbacks call `clearInterval`; timing variance is expected and visible.
It also immediately clears a one-hour interval, so a completed windowless run
proves cancellation releases the sleeping native helper promptly.

`tests/manual/frame-clock-cadence.html` records 48 requestAnimationFrame gaps
while forcing style, layout, paint, blur rasterization, and draw work. Its
warm-up lets the estimator settle; the measured average should remain near
33ms on a sustainable page or a consistent 33ms multiple under overload,
without immediate catch-up bursts. A trace also shows animation-frame tasks
starting before and overlapping raster-worker execution.

`tests/manual/raster-draw-thread.html` provides a large blurred subtree to
reload while the user types, moves the address cursor, clicks, and switches
tabs. Input remains responsive, and traces attribute `task:raster_and_draw` to
the named per-window worker while SDL event and presentation calls remain on
the Browser/UI thread.

`tests/manual/task-scheduler.html` combines 32 CPU-heavy same-deadline timeout
callbacks with 48 animation frames. Frame cadence remains visible while every
timeout must eventually complete, covering both priority and starvation.

`tests/manual/background-color-transition.html` exercises a one-second RGBA
transition from translucent red through purple to opaque blue. The final DONE
state is deterministic; the intermediate color change is verified visually.

`tests/manual/easing-functions.html` compares default `ease`, `linear`,
`ease-in`, and `ease-out` background-color transitions on one shared timeline.
Their midpoint colors differ while their duration and final blue endpoint match.

`tests/manual/composited-animations.html` runs simultaneous opacity and
`translate(...)` transitions over a long page. In an interactive trace the
initial build rasterizes once; later animation frames and root scrolls that stay
inside the interest region are draw-only and leave no ghost image.

`tests/manual/width-height-animations.html` animates both block dimensions.
The panel grows in both axes while its text continuously reflows onto fewer
lines, proving width frames enter layout rather than only repainting a box.

`tests/manual/css-animations.html` covers the book's two named-keyframe demos.
Its infinite alternate opacity animation stays composited, while the matching
width animation repeatedly changes line wrapping and therefore relayouts.

`tests/manual/transform-animation-overlap.html` moves an animated transform
into a later-painted static card. The later blue card must remain above the
mover throughout every cycle, proving animated transforms establish a
conservative compositor-plane merge barrier while frames remain draw-only.

`tests/manual/sparse-composited-layers.html` separates compatible static paint
chunks by roughly 1800px around a composited effect. Raster-worker inspection
must show separate tightly cropped surfaces instead of one sparse page-height
plane, while both endpoints remain visually correct when scrolling.

`tests/manual/short-composited-layers.html` compares a surface-free animated
solid-color plane with a glyph-bearing surface-backed plane. Both must preserve
opacity, translation, paint order, and draw-only scrolling without ghosting.

`tests/manual/opacity-plus-draw.html` compares nested 0.5 and 0.8 opacity on an
animated composited child with a precomputed 40% red reference. The child must
keep the same color while moving, proving ancestor alpha is folded into its
single cached-surface draw without a temporary copy or stale animation state.

`tests/manual/threaded-loading.html` combines two external scripts and two
same-specificity stylesheets. Run its adjacent threaded Python server to give
each response equal latency: all four requests start together while the visible
script result and final green style prove that consumption remains in DOM
source order. With `ZIBRA_TRACE=1`, the document navigation and resource-batch
spans must be attributed to `Networking thread`, while the four batch requests
still overlap.

Choose the narrowest check that covers the pipeline stage under change. A DOM
or parser regression should normally add a DOM dump or unit fixture before a
full screenshot fixture.

`tests/manual/canvas-2d.html` exercises atomic canvas layout with explicit
dimensions, retained 2D context identity, rectangles, paths, arcs, transforms,
alpha, clearing, and a non-fatal unsupported drawImage call. Unit coverage owns
the 300x150 defaults, same-size dimension reset, lazy-context repaint, and
display/raster snapshot boundaries.

`tests/manual/background-images.html` uses a local ASCII PPM to compare
explicit, percentage, contain, cover, and rounded-crop geometry. Its unmatched
broken URL is also a manual assertion that post-cascade discovery performs no
unused fetch; `browser_background_images.zig` provides the deterministic count.

`tests/manual/object-fit.html` puts the same wide diagnostic PPM into fixed
replaced-element boxes. It distinguishes stretched `fill`, centered letterbox
`contain`, and centered fractional `cover` cropping without pixel spill.

`tests/manual/lazy-loading.html` distinguishes eager, near-viewport lazy, and
far lazy requests using HTTP-log query suffixes. Its far intrinsic-size image
must reflow the green marker after decode and remain stable without refetching.

`tests/manual/aspect-ratio.html` covers width-derived and height-derived iframe
boxes, an explicit image ratio, and an `auto <ratio>` lazy-image fallback that
switches to the decoded natural ratio without a second request.

`tests/manual/image-placeholders.html` covers zero- and one-axis unloaded image
placeholders, post-decode reflow, and broken-image fallback visibility for
missing, empty, and meaningful `alt` values. Serve it over HTTP so the missing
resources reach a terminal decode failure and the lazy request is visible.
