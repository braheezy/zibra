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
- Address-bar interpretation belongs to `chrome.zig`, not general URL or link
  resolution. Explicit schemes and obvious bare hosts navigate directly;
  ordinary text becomes a form-encoded Google query. Keep document-authored
  links strict so a malformed link never silently becomes a search.
- Address-bar editing uses a byte insertion point in the inclusive range
  `0..address_bar.items.len`. SDL admits only printable ASCII into this buffer,
  so Left, Right, insertion, and Backspace operate on bytes; focus, blur, and a
  successful Enter reset both the editing buffer lifecycle and cursor. While
  the address bar is focused it consumes editing and activation keys, even at
  cursor boundaries, so a stale DOM focus pointer cannot also edit the page.
- Each tab owns an indexed root-navigation history. Successful ordinary
  navigation truncates entries after the current index before appending; Back
  and Forward retain the list and move the index only after the replacement
  document loads. History entries and the index are tab-worker state. Chrome
  reads only the atomic back/forward availability flags and schedules traversal
  back onto that worker. A traversal clones its target URL for the load so the
  canonical entry remains owned until navigation succeeds.
- Tab workers must not create tabs or mutate browser chrome collections.
  Cross-thread new-tab requests transfer an owning `Url` through
  `Browser.pending_new_tabs`; the browser thread drains that queue.
  `queueNewTab` takes ownership only on success, while `newTab` consumes its
  URL on entry, including failure paths. These queued tabs stay grouped in the
  requesting native window; only Ctrl+N creates another native window.
- A frame's `css_texts` owns decoded linked stylesheets and copied `<style>`
  text in DOM order. Its author rules borrow those buffers; rebuild and retire
  the text and rules as one generation for root documents and iframes.
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
  active Browser draw/layer/display state under `Browser.lock`. Schedule the
  replacement paint before any fallible mutation step. Preserve focus when the
  mutation root itself survives; clear it only for a removed descendant.
- Content clicks walk the retained list in reverse paint order and then walk
  the hit node's DOM ancestry. `link_bounds` and `iframe_bounds` may support
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
