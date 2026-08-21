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

`tests/manual/multiple-windows.html` exercises nonrepeating Ctrl+N native-window
creation, per-window tab/chrome/focus/scroll state, addressed close behavior,
and process-shared bookmark/visited state.

Choose the narrowest check that covers the pipeline stage under change. A DOM
or parser regression should normally add a DOM dump or unit fixture before a
full screenshot fixture.
