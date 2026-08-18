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
