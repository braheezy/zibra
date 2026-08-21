# Browser subsystem guide

This directory owns the process `BrowserApp`, per-native-window `Browser`
instances, tabs/frames, navigation orchestration, the compositor, SDL
integration, layout, font resources, and chrome.

Read [`../../docs/architecture-and-lifetimes.md`](../../docs/architecture-and-lifetimes.md)
before changing `root.zig`, `tab.zig`, `render/`, or browser task scheduling.

- `app.zig` is the sole interactive owner of SDL event polling, text input, the
  shared `BrowserSession`, and shared `MeasureTime`. It keeps every `Browser`
  heap-stable, routes window-targeted SDL events by native ID, ticks every live
  window, and removes an entry before destroying its native window. SDL quit is
  process-wide; Escape becomes process-wide only after routing through a live
  source window, so stale queued events are harmless.
- `root.zig` owns one native window, that window's tabs/chrome/render state,
  and browser-side snapshot shutdown order. Browser-side snapshot retirement
  must precede document or tab destruction. Standalone screenshot construction
  additionally owns SDL, text input when applicable, session, and measurement;
  App-window construction borrows those four services explicitly.
- `tab.zig` owns frames, document generations, task serialization, and helper
  quiescence. Queued or detached work must carry a stable document identity,
  not a borrowed frame pointer.
- Each tab owns a sentinel-terminated copy of its root document title. Tab
  workers replace it under `Browser.lock`; only the interactive App/UI thread
  may pass it to the addressed native window, including after tab switches.
- Browser-session state lives in `session_state.zig`, separately from any
  native window. It owns the shared HTTP client, cookie jar, response cache,
  and a dedicated network mutex, plus canonical visited and bookmarked URL
  strings under an independent metadata mutex. Bookmark snapshots own
  independent sorted string copies. DOM anchors retain only an `is_visited`
  boolean; monotonically increasing generations let `BrowserApp` broadcast
  visited RAF work and bookmark chrome reraster work to every live window
  without nesting session and browser locks.
- Per-document cookie callbacks resolve their live frame URL synchronously,
  then read or update the session jar by host under `network_lock`. The result
  returned to JavaScript is an independent allocation; no script or frame
  retains a cookie-map key or value pointer after releasing that lock. Cookie
  callbacks sample the session's real clock and may synchronously evict an
  expired owning entry while holding that lock.
- Address-bar interpretation belongs to `chrome.zig`, not general URL or link
  resolution. Explicit schemes and obvious bare hosts navigate directly;
  ordinary text becomes a form-encoded Google query. Keep document-authored
  links strict so a malformed link never silently becomes a search.
- Native chrome is an internal HTML document: buttons represent new-tab and
  history/bookmark actions, the address field is an input, and tab names are
  anchors. `Chrome` owns a dedicated UI-thread-only Layout/FontManager, parsed
  stylesheet, DOM, document layout, and retained provenance-bearing display
  list; never share the tab-worker layout engine for this work. Rebuilds retire
  the old list before its layout, DOM, and source buffer, in that order. Chrome
  clicks hit-test painted commands and walk their internal DOM ancestry to a
  semantic action; fixed rectangles remain only as a pre-raster/test fallback.
  Preserve the 66px chrome boundary so changing its implementation does not
  shift document screenshots or viewport calculations.
- Address-bar editing uses a byte insertion point in the inclusive range
  `0..address_bar.items.len`. SDL admits only printable ASCII into this buffer,
  so Left, Right, insertion, and Backspace operate on bytes; focus, blur, and a
  successful Enter reset both the editing buffer lifecycle and cursor. While
  the address bar is focused it consumes editing and activation keys, even at
  cursor boundaries, so a stale DOM focus pointer cannot also edit the page.
- Return in page content has its own `Tab.enter` path, separate from Space and
  generic focused-element activation. A focused text-entry input dispatches
  `keydown`, then submits its containing form through the same submit-event and
  navigation path used by buttons; `preventDefault` cancels the default and a
  missing `action` resolves to the current document. Form methods default to
  GET; GET replaces the action query with the encoded named inputs and carries
  no payload, while an explicit case-insensitive POST keeps that encoding in
  the owned request body. Inputs outside forms and known non-text input types
  do not implicitly submit.
- Before chrome or another DOM target takes focus, enqueue or call `Tab.blur`
  first; it clears focused state across the complete frame tree, resets
  accessibility focus, and triggers a repaint when a content cursor was
  removed. Address-bar transitions preserve tab-worker ownership by enqueueing
  that blur instead of mutating frame focus directly from the UI thread.
- Checkbox state is the presence of the DOM `checked` attribute, not a second
  widget-owned boolean. Primary or focused activation dispatches the cancelable
  click first, then toggles that attribute and repaints. Form encoding omits
  unchecked checkboxes and uses `on` for a checked checkbox without `value`.
- Hidden inputs remain successful form controls but create no layout box,
  painted command, hit target, focus stop, or accessibility node. Password
  inputs retain ordinary text-entry editing and submission behavior; only
  presentation is masked, with one star per grapheme, and accessibility output
  must not log or name the backing value.
- A `<button>` is an atomic inline whose payload owns a temporary contained
  block-layout subtree. Descendant commands and interactive bounds are laid
  out in local coordinates, rebased onto the surrounding persistent block
  origin, and translated only after the outer line chooses a baseline. The
  orange box expands around tall, oversized, and negative-offset descendants;
  descendant links and inputs retain their own topmost paint provenance.
  Persistent block paint caches recursively own nested display containers;
  every frame paint deep-clones cached items before effects or snapshots take
  ownership, so retiring one frame never poisons a later paint-only pass.
- Each tab owns an indexed root-navigation history. Every heap-stable entry
  owns its URL, request method, and an independent POST-body copy when present;
  prepare all entry allocations before retiring the current document.
  Successful ordinary navigation truncates entries after the current index
  before appending; Back and Forward retain the list and move the index only
  after the replacement document loads. History entries and the index are
  tab-worker state. Chrome reads only the atomic back/forward availability
  flags and schedules traversal back onto that worker. GET targets replay
  immediately. A POST target publishes a generation-stamped request under
  `Browser.lock`; the UI thread asks through a native modal dialog, cancellation
  leaves history untouched, and confirmation schedules a body-copying replay
  only if the target generation is still current.
- Tab workers must not create tabs or mutate browser chrome collections.
  Cross-thread new-tab requests transfer an owning `Url` through
  `Browser.pending_new_tabs`; the browser thread drains that queue.
  `queueNewTab` takes ownership only on success, while `newTab` consumes its
  URL on entry, including failure paths. These queued tabs stay grouped in the
  requesting native window; only Ctrl+N creates another native window.
- A frame's `css_texts` owns decoded linked stylesheets and copied `<style>`
  text in DOM order. Its author rules borrow those buffers; rebuild and retire
  the text and rules as one generation for root documents and iframes.
- Attached structural DOM mutation marks that frame's document resources
  dirty. Before the next style pass, the tab worker queues newly attached
  scripts once and rebuilds the complete author-sheet generation from the
  live DOM, so inserted `<style>`/`<link>` nodes participate and detached links
  stop participating. Script source tasks own their copies after queueing;
  removing a script never rolls back code and reattaching that same element
  never evaluates it again.
- `render/layout.zig` and `render/font.zig` borrow DOM/image state and own
  layout/font resources. `FontManager` owns canonical RGBA glyph bitmaps;
  display-list `Glyph` values borrow those bytes, and `pixel_mode` tells paint
  whether to tint an alpha mask or preserve native color. Layout must retire
  before DOM, and display snapshots must retire before `FontManager`.
- Every frame retains its authoritative uncomposed display list for synchronous
  worker-thread clicks. Its optional `DisplayItemSource` pointers borrow the
  current layout and DOM generation, so retire that list before layout rebuild
  or DOM teardown. Iframe composition creates a separate recursively owned
  list, clears all source metadata, and transfers only that copy to
  `Browser.commit`; clean-tab activation must republish the same way. Source
  activation must consult the typed layout-origin resolver and validate any
  inline fragment node against that origin. Apply compositor-only opacity
  updates to this retained list before committing them to the browser snapshot;
  recurse through transforms and reraster any ancestor layer that flattened the
  updated effect into its owned item tree.
- Structural DOM mutation is a synchronous generation boundary, distinct from
  ordinary render invalidation. Before a child array moves or a child is
  destroyed, mark layout/render dirty, retire the frame's display and DOM-keyed
  interaction state, clear tab accessibility/composited borrows, and retire
  active Browser draw/layer/display state under `Browser.lock`. Then destroy
  the mutating frame's complete layout dependency graph while the old DOM is
  still alive; the next full render rebuilds it. Schedule the replacement paint
  before any fallible mutation step. Preserve focus when the mutation root
  itself survives; clear it only for a removed descendant.
- Content clicks walk the retained list in reverse paint order. A primary hit
  dispatches one click at the painted element and bubbles through its
  snapshotted DOM ancestry, even when no native control owns a default action;
  iframe events stay inside the child document. Resolve link/input/button
  default actions through stable JS handles after listeners return, and let
  `preventDefault` cancel the action without conflating it with
  `stopPropagation`. `link_bounds` and `iframe_bounds` may support
  layout-derived accessibility/coordinate bookkeeping, but must not select a
  click target; keep focus, accessibility, and fragment bounds intact.
- `scroll.zig` is the single source of truth for CSS scroll ranges and native
  scrollbar-thumb geometry. Clamping and drawing must use the same metrics.
- Fragment targets are layout-derived document-space positions that borrow DOM
  node identity. A `Frame` copies them with its other hit-test data and retires
  them before layout or DOM. Full navigation applies the fragment after layout;
  same-document fragment links update URL/history and scroll on the tab worker,
  then repaint without replacing the document.
- Successful root/child-frame document fetches, same-document fragment
  navigations, and queued middle-click targets add visited entries. Redirects
  record both the requested and final destinations. Root and iframe documents
  resolve anchors with the same navigation policy used by clicks, and text
  paint checks the nearest anchor's annotation through synchronous DOM-parent
  borrows.
- Parent CSP checks both the requested and final redirect destinations before
  installing an initial iframe or a later navigation in an existing child
  frame. Blocked targets are not recorded as visits.
- Chrome owns separate complete URL snapshots for optimistic address display
  and the latest committed document. Public optimistic updates copy under
  `Browser.lock` before navigation ownership can move to a worker; the `*`
  button toggles only the committed snapshot and paints a yellow selected
  background. Document navigation for `about:bookmarks` uses
  `NavigationDocument`, whose explicit owned-body field covers both generated
  HTML and ordinary allocated fetches.
- Certificate-validation failures become owned, browser-generated warning
  documents with no bypass and are not recorded as successful visits. Each
  root frame commits its certificate-error bit with its URL. Chrome shows a
  lock only when the displayed URL exactly matches a successfully verified,
  committed HTTPS URL, so pending text and warning documents cannot inherit a
  stale secure indicator.
- Basic text direction keeps glyphs in source order and aligns completed lines:
  `-rtl` supplies the document fallback, while the nearest block ancestor's
  `dir=rtl` or `dir=ltr` overrides it. Unicode bidi reordering, `dir=auto`, and
  contextual script shaping are not implemented.
- An `h1` whose whitespace-separated class list contains `title` centers each
  completed line independently. Keep this alignment stable for the whole
  inline block; line flushing must not consume it.
- Superscript state is scoped to the DOM/layout subtree beneath `sup`. Its
  glyphs use half the inherited text size and align their top with the tallest
  normal glyph without changing that line's normal baseline.
- Small-caps state is scoped to the DOM/layout subtree beneath `abbr`.
  Lowercase ASCII graphemes use an uppercase bold glyph at four-fifths of the
  inherited size; uppercase letters, numbers, punctuation, and following
  siblings retain their inherited font.
- Preformatted state is scoped to the DOM/layout subtree beneath `pre`.
  Preserve spaces and explicit CR, LF, and CRLF line breaks, advance empty
  lines, suppress automatic wrapping, and use the monospace face without
  suppressing nested inline styles.
- `font-family` is inherited. The supported CSS family list resolves normal
  proportional faces and common Courier/monospace aliases to platform fonts;
  CJK, symbol, and emoji graphemes retain their specialized fallback faces.
  Glyph caches belong to the selected font face, so never reuse a glyph across
  family selections. The user-agent stylesheet makes `code` monospace.
- Block `width` and `height` support `auto` and non-negative pixel lengths.
  Resolve a fixed width before laying out descendants so it controls wrapping;
  replace the content-derived height afterward, allowing visible overflow.
  Synthesized anonymous blocks always retain their automatic dimensions.
- Block participation is driven by computed `display`, not a tag list in
  layout. The user-agent stylesheet owns HTML's block defaults; direct child
  display fields invalidate their parent's anonymous/block box grouping.
- Soft hyphens are invisible discretionary breaks. Track every candidate in
  the current word, use the latest one whose visible hyphen fits, and transfer
  the suffix to the next line without duplicating owning inline payloads.
- Keep browser rendering work and isolated inspection modes separate. A DOM
  dump must not construct `Browser` merely to reuse a convenience method.
- Screenshot mode is windowless: initialize SDL video only for SDL_ttf's macOS
  requirement, create no SDL window/renderer/texture, wait for tab and detached
  work to become quiescent, raster to z2d surfaces, and export the root surface.
- Each `FontManager` keeps its existing paired SDL_ttf init/quit reference.
  `BrowserApp` holds one additional process reference until every window and
  its FontManager have been destroyed; SDL_ttf's documented init count makes
  closing one window safe while fonts in another remain live.

For changed browser behavior, add a deterministic manual fixture and run the
relevant unit, DOM-dump, and macOS screenshot checks from the root guide.
