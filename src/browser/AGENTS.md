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
  navigation/render orchestration, and browser-side snapshot shutdown order.
  It re-exports shared rendering types for compatibility but does not own their
  implementation. Browser-side snapshot retirement must precede document or
  tab destruction. Standalone screenshot construction additionally owns SDL,
  text input when applicable, session, and measurement; App-window
  construction borrows those four services explicitly.
- `render/display_list.zig` owns display-command types, recursive container
  cleanup, painted hit testing, and composited-layer data. It must remain free
  of `Browser` and SDL dependencies. `render/effects.zig` owns pixel-level
  software effects, `render/raster_snapshot.zig` owns the deep-copy boundary
  used to hand commands and copied leaf pixels to the raster worker, and
  `render/compositor_cache.zig` owns worker-thread planes and scalar opacity /
  translation updates. Operations requiring per-window drawing state remain
  Browser methods.
- `root.zig` remains an oversized legacy coordinator, so do not add another
  standalone algorithm or data-owner there by default. The remaining natural
  seams include fetch/resource coordination and the per-window presentation
  worker; extract one only when its inputs, ownership, and shutdown order can
  be expressed without a circular facade.
- `tab.zig` owns frames, document generations, task serialization, and helper
  quiescence. Queued or detached work must carry a stable document identity,
  not a borrowed frame pointer.
  Each child Frame also stores the numeric authored zoom inherited at its
  iframe boundary. Recompute it from the styled containing-node ancestry
  before child layout, rescale the already-published viewport by the factor
  delta, and schedule a media/style follow-up because iframe media queries use
  the unscaled CSS width. Parent composition publishes changed iframe geometry
  through `Frame.updateViewportFromParent`; dirty that frame's complete layout
  subtree before scheduling the media/style follow-up so neither its exact
  `width` rules nor ordinary line layout reuse the prior viewport. Root Frames
  always start at one.
- `tab_tasks.zig` owns heap payloads transferred from Browser/UI work to the
  serialized Tab runner. Its comptime Browser parameter avoids a root import
  cycle. Simple input/history/resize work shares one tagged action adapter;
  navigation and script payloads retain specialized URL/body ownership.
- `js_context.zig` is the stable synchronous JavaScript host-callback identity
  embedded in each Frame. `script_tasks.zig` owns detached timer, animation,
  asynchronous XHR, cookie, and postMessage adapters plus their queued cleanup
  payloads. It receives Browser and document-handle types at comptime to avoid
  importing the per-window coordinator and creating an import cycle.
  A queued postMessage owns both the canonical target-origin policy and the
  source-origin/message copies; resolve its generation-stamped target first,
  then compare that live document's URL at delivery rather than trusting a
  send-time string comparison.
- `navigation.zig` owns browser-generated certificate-warning documents and
  transport-security classification. `frame_timing.zig` owns frame cadence
  estimation and absolute deadlines. `window_geometry.zig` owns pure resize
  derivation; SDL resource creation and installation remain in Browser.
- `image_loader.zig` owns HTML-image eager/lazy selection, per-batch URL
  deduplication, fetch/decode, and stable broken-image fallback. A terminal
  fallback is tagged separately from decoded content so layout paints its red-X
  pixels only for a non-empty `alt`; missing and empty alternate text suppress
  the icon without causing another request. Frames copy image-node bounds from
  layout; lazy selection uses each frame's scroll and a one-CSS-pixel-viewport
  preload margin after accessibility zoom conversion. A newly decoded image
  always schedules layout and paint because its natural dimensions may change
  geometry.
- `render/replaced_sizing.zig` resolves unscaled image and iframe dimensions
  from computed CSS, HTML attributes, natural image size, and `aspect-ratio`.
  Relative CSS dimensions receive explicit font-size and containing-block
  bases. Parent layout and initial iframe viewport setup share this resolver;
  layout applies authored zoom only after both axes have been derived. A lazy image's
  `auto <ratio>` value reserves the fallback ratio until decoded pixels provide
  the natural one. Without pixels or a usable ratio, only explicitly authored
  image axes are retained; an unspecified axis is zero.
- A Tab also owns the native `setInterval` cancellation registry under its
  interval mutex. Keys include window ID, document generation, and JavaScript
  handle. Sleeping one-shot helpers poll this registry at most every 10ms;
  `clearInterval`, navigation, frame teardown, and Tab shutdown remove the
  applicable keys before document state can retire. JavaScript interval
  callbacks and rescheduling still run only on the serialized Tab worker.
- Animation frames use absolute monotonic `awake`-clock deadlines, not a new
  relative delay after each completed frame. A continuous chain advances from
  its preceding deadline using a bounded estimator-selected cadence; an idle
  chain starts from the current clock. The estimator smooths tab animation work
  and raster-worker/software-presentation work independently, selects the
  slower overlapping stage, and rounds up to a 33ms cadence bucket with 3ms of
  headroom. Overload raises the estimate quickly, recovery lowers it gradually,
  and active-tab or successful root-document changes reset it. Every detached
  timer and queued animation task carries a generation so superseded helpers
  cannot publish work or clear newer state. The Browser UI tick starts
  requested tab-worker animation work before snapshotting the preceding commit
  for the raster worker, allowing the two threads to overlap. CSS animations
  must publish `needs_animation_frame`, just like JavaScript
  `requestAnimationFrame`, before attempting to schedule again.
- CSS transition frames first normalize elapsed frame count, then apply the
  Element-owned timing function before property interpolation. Easing changes
  values only; it does not alter the absolute animation-frame scheduling path.
  Opacity and `translate(...)` transform transitions publish compositor
  updates; simultaneous values for one element must share a stable numeric
  compositor ID and remain draw-only after their initial raster.
- Zoom and native-width changes invalidate the tab's media environment as well
  as layout. On the serialized render path, every frame reparses its retained
  author sheets using its current CSS-pixel viewport width, dirties the DOM
  style subtree, and only then runs style/layout/paint. Both inclusive
  `max-width` and exact `width` consume this value. Child-frame widths are
  authored-zoom-scaled layout geometry and divide out that inherited factor;
  root widths divide native pixels by page zoom.
- Browser task producers classify animation frames and native input as urgent,
  navigation and script discovery as normal, and timeout/interval/XHR/message
  callbacks as JavaScript-low. Do not infer priority from the trace label:
  `Task.init` requires both so renaming diagnostics cannot change scheduling.
- Every Browser owns one named raster-and-draw `TaskRunner`. The UI thread
  rebuilds chrome, then clones the chrome/page command trees into a
  self-contained job while `Browser.lock` stabilizes their borrowed source
  pixels. Jobs independently own structural containers, blend strings, glyph
  bitmaps, and image bytes; the worker may therefore raster z2d surfaces after
  a tab commit, mutation, or navigation retires the source generation. A newer
  dirty commit makes an in-flight result stale. Jobs, z2d temporaries, caches,
  and result surfaces use the thread-safe SMP allocator; when a result becomes
  `root_surface`, Browser tracks that allocator through resize/teardown. The
  worker never calls SDL;
  the UI thread accepts only a current completed surface, uploads it to the
  window texture, copies it to the renderer, and presents it. Input handlers
  only publish dirty work and return. Shutdown joins this runner before tabs,
  font caches, z2d surfaces, SDL handles, or shared measurement retire.
  An active tab without a committed display list is a valid blank-content
  state: raster clears the worker tab cache and does not require a tab cache
  until committed content exists. Draw-only tasks for committed content still
  require a valid worker cache.
  When a committed page has top-level composited opacity or translation
  effects, the worker retains ordered transparent planes instead of one
  assembled tab bitmap. Static strata are tightly cropped within the interest
  region; nearby paint can expand them, but a merge whose bounding surface
  would exceed one megapixel starts a new plane instead. Animated planes retain
  either their own raster or, for at most three cheap primitive commands, an
  independently owned pointer-free command snapshot. Short planes skip raster
  and replay those commands during draw with the plane's current opacity and
  translation; glyphs, images, filters, blend modes, and unsafe opacity groups
  stay surface-backed. A static merge that stops being eligible promotes the
  plane transactionally to a surface. Stable dynamic
  planes use tight current bounds for overlap-safe backward merging of later
  static paint. An actively animated transform is a permanent merge barrier
  for that raster generation, so later content cannot move beneath it when
  translation creates overlap. Unsupported nesting or masking falls back to a
  full raster rather than losing an update. When an opacity-only `Blend` draws
  one retained composited layer, fold its alpha into the draw command and
  multiply it with the layer's live opacity at final composition; never copy
  the cached surface merely to apply that ancestor alpha.
- Each tab owns a sentinel-terminated copy of its root document title. Tab
  workers replace it under `Browser.lock`; only the interactive App/UI thread
  may pass it to the addressed native window, including after tab switches.
- Browser-session state lives in `session_state.zig`, separately from any
  native window. It owns the shared HTTP client, cookie jar, response cache,
  one heap-stable networking task runner, and a dedicated network-data mutex,
  plus canonical visited and bookmarked URL strings under an independent
  metadata mutex. Every ordinary Browser fetch synchronously bridges through
  that runner; only its joined linked-resource batch workers call transport
  directly. The runner is stopped after all windows but before its borrowed
  MeasureTime and transport state. Bookmark snapshots own
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
- Cross-origin XHR is fetched rather than rejected up front. It sends the
  caller's canonical Origin and target-host cookies, then exposes the body only
  for an exact or wildcard Access-Control-Allow-Origin response. Synchronous
  denial becomes `CrossOriginBlocked`; asynchronous denial discards the owned
  response and never queues `onload`. CSP can still block before the fetch.
- Each Frame stores the Referrer-Policy received with its current document
  generation. Install it before discovering images, iframes, scripts, and
  stylesheets; navigations and XHR also use that source policy. Async XHR must
  copy the policy alongside its cloned target and referrer so later navigation
  cannot change an in-flight request's disclosure decision.
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
  Chrome rebuild/paint stays on that UI thread; only its independently owned
  command/pixel snapshot crosses to the raster worker. Preserve the 66px chrome
  boundary so changing its implementation does not shift document screenshots
  or viewport calculations.
- Screen-reader document reading is incremental. `Tab.advanceAccessibility`
  advances one preorder accessibility-tree node, queues it for speech, stores
  the current node as the persistent amber highlight, and schedules paint; the
  synthetic document root is skipped for the first visual step. Every Tab owns
  one named accessibility worker. Queueing flattens role/name/value into owned
  bytes, so no speech payload retains a DOM, accessibility-tree, or Tab pointer.
  The serialized Tab worker stops first during shutdown; the accessibility
  worker then cancels pending utterances and joins an active backend call before
  tree strings and shared measurement retire. Turning the screen reader off
  also clears pending speech. Accessibility-tree rebuilds remap the reading /
  highlight pointers through their DOM nodes before retiring the prior tree.
  The F4 key and the `read page` voice command each advance once.
- F6 toggles the active Tab's forced-colors setting. The change invalidates
  conditional stylesheet rules plus style, layout, and paint; every frame then
  receives the same `(forced-colors: active)` media environment. Page paint
  uses the renderer's semantic four-color palette, while content images and
  color glyph bitmaps remain content rather than author CSS colors. Decorative
  CSS background images are suppressed.
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
- Sequential Tab focus is tab-wide. Traverse the root Frame and its descendant
  Frames in preorder, exhaust each frame's DOM-order focusable elements before
  entering its children, skip frames with no sequential focus stop, and wrap
  only after the complete frame tree. Shift-Tab is the exact reverse order.
  Cross-frame transitions still use the ordinary tab-wide blur/focus handoff
  so only one Frame may retain DOM focus or a focus-visible marker.
- A Tab retains the latest pointer/keyboard focus modality. Primary page clicks
  publish pointer modality before event listeners run; keyboard editing,
  activation, scrolling, and focus traversal publish keyboard modality and
  promote an existing pointer focus. A focus transition snapshots the result
  in `Element.is_focus_visible`: pointer-focused links/buttons suppress the
  indicator, visible inputs and contenteditable targets retain it, and every
  keyboard-focused target shows it. Clicked links and buttons are focused
  before their default action continues, then recovered through a stable JS
  handle because the focus listener may structurally mutate the target.
- JavaScript `Node.focus()` runs synchronously on the serialized tab worker.
  It forces pending style/layout work before consulting the frame's focus
  bounds, rejects focusable-but-unlaid-out targets, scrolls the refreshed
  bounds into the frame viewport, inherits the Tab's current modality, and
  re-resolves the numeric node handle after blur listeners. Focus and blur
  events do not bubble. A worker publishes content-focus intent by stable Tab
  identity; only the UI tick may blur the chrome-owned address input.
- Page focus indicators paint after document content as two coincident outline
  commands: a 4px white stroke below a 2px black stroke. Mixed inline content
  publishes one bounds entry per wrapped visual line, including fragments from
  nested inline descendants; a block-displayed focus target publishes only its
  complete block box. Paint consumes the same `is_focus_visible` state as the
  CSS pseudo-class, follows every resulting bounds entry only when that state
  is active, and remains distinct from the amber accessibility highlight.
- SDL finger coordinates are normalized; convert them against the addressed
  Browser's current native-window dimensions before dispatch. Each Browser's
  UI-thread-only touch tracker keys contacts by both touch-device and finger
  identity, accepts a release as a primary click only while it remains within
  the 10px tap slop, and clears unfinished contacts on focus loss. Keep a drag
  canceled even if it returns to its start. SDL's synthetic touch-mouse and
  mouse-touch mirror events must be ignored so one physical action cannot
  activate twice. A completed tap reuses `Browser.handleClick`, preserving
  chrome/page hit testing and the existing tab-worker task boundary without
  retaining DOM or layout pointers.
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
- Each tab owns an indexed joint session history for its root and iframe tree.
  Every entry independently owns the resulting URL/request, an index path from
  the root Frame, the document-replacement bit, and an owned snapshot of the
  target subtree immediately before navigation. Never retain a `*Frame` in
  history: replay can destroy and recreate the complete subtree. Prepare the
  path, URL/body copies, recursive prior snapshot, and list capacity before
  retiring a document. Successful navigation truncates entries after the
  current index before appending. Back restores the current action's prior
  subtree; Forward reapplies the next action, so interleaved sibling-frame
  navigation leaves unrelated frames untouched. Move the index only after the
  complete restore succeeds. Chrome reads only atomic availability flags and
  schedules traversal on the tab worker. A replay that actually needs one or
  more POST requests uses the existing generation-stamped native confirmation;
  same-document fragment traversal never prompts because it sends no request.
- Tab workers must not create tabs or mutate browser chrome collections.
  Cross-thread new-tab requests transfer an owning `Url` through
  `Browser.pending_new_tabs`; the browser thread drains that queue.
  `queueNewTab` takes ownership only on success, while `newTab` consumes its
  URL on entry, including failure paths. These queued tabs stay grouped in the
  requesting native window; only Ctrl+N creates another native window.
- A frame's `css_texts` owns decoded linked stylesheets and copied `<style>`
  text in DOM order. Its author rules and named keyframes borrow those buffers;
  rebuild and retire text, rules, and keyframes as one generation for root
  documents and iframes.
- External classic scripts and linked stylesheets are first discovered into a
  fixed caller-owned batch. The tab submits that complete batch as one task to
  the session networking runner. Each entry owns its resolved URL, referrer,
  and eventual response; the network task starts and joins all transport
  workers before any entry or document generation can retire. Completion order
  is irrelevant: scripts are queued and styles are parsed by walking the DOM
  in source order after the join. Root loads, child-frame loads, and mutation
  rescans share this path.
- CSS backgrounds use the separate post-cascade loader in
  `background_images.zig`. Run it after every initial or dynamic style pass for
  root and child frames, not during eager DOM resource discovery: unmatched,
  overridden, `display:none`, hidden-input, `none`, and unsupported image
  values must cause no fetch. Forced-colors disables and releases decorative
  background resources at this same boundary. Resolve selected URLs against the document,
  enforce the frame CSP and Referrer-Policy, deduplicate one pass, and retain
  blocked/broken attempt identities without a placeholder. Before replacing
  Element-owned decoded pixels, retire both active Browser render state under
  its lock and the frame list that borrows them.
- Attached structural DOM mutation marks that frame's document resources
  dirty. Before the next style pass, the tab worker queues newly attached
  scripts once and rebuilds the complete author-sheet generation from the
  live DOM, so inserted `<style>`/`<link>` nodes participate and detached links
  stop participating. Script source tasks own their copies after queueing;
  removing a script never rolls back code and reattaching that same element
  never evaluates it again. Each attached iframe Element also carries the
  numeric window ID of its live child Frame. The synchronous post-mutation
  boundary validates those IDs, rebinds surviving `frame_element` pointers in
  DOM order, and destroys contexts whose Elements disappeared. The deferred
  resource pass then loads only marker-free new iframes through the ordinary
  CSP/referrer/document pipeline; do not start network work while Kiesel is in
  the mutation callback.
- `render/layout.zig` and `render/font.zig` borrow DOM/image state and own
  layout/font resources. `FontManager` owns canonical RGBA glyph bitmaps;
  display-list `Glyph` values borrow those bytes, and `pixel_mode` tells paint
  whether to tint an alpha mask or preserve native color. Layout must retire
  before DOM, and committed display snapshots must retire before `FontManager`.
  Raster jobs are the exception: they copy every glyph/image buffer before
  releasing `Browser.lock` and do not borrow either source generation.
- Every frame retains its authoritative uncomposed display list for synchronous
  worker-thread clicks. Its optional `DisplayItemSource` pointers borrow the
  current layout and DOM generation, so retire that list before layout rebuild
  or DOM teardown. Iframe composition creates a separate recursively owned
  list, clears all source metadata, and transfers only that copy to
  `Browser.commit`; clean-tab activation must republish the same way. Source
  activation must consult the typed layout-origin resolver and validate any
  inline fragment node against that origin. Apply compositor-only opacity and
  translation updates to this retained list before committing them to the
  browser snapshot. The raster worker accepts only numeric compositor IDs, not
  those DOM pointers; unsupported/flattened effect trees request a safe full
  raster.
- CSS `filter: blur(<length>)` is an owning blend wrapper around the complete
  element subtree. Raster it into premultiplied RGBA, blur that image, then
  apply overflow clipping, group opacity/mix-blend, and finally translation.
  Keep each effect wrapper in its own layer: neighboring filters and `dst_in`
  masks are ordered groups and must never be merged. Blur expands visual layer
  bounds but does not expand the DOM hit target.
- CSS transition state advances only on the serialized Tab worker. Opacity and
  `translate(...)` transforms emit composited scalar updates and can skip
  paint; `background-color` marks paint dirty; width/height retain a
  pixel-serializing animation value and mark the element's layout owner dirty
  on every frame so block geometry, descendant line wrapping, paint, and raster
  are regenerated.
- Named CSS keyframe animations use that same property-specific interpolation
  and invalidation path plus an Element-owned cycle controller. `alternate`
  cycles hold each terminal endpoint for one render before reversing; opacity
  and translation remain compositor-only, while width/height continue to
  relayout. Any style pass that creates a keyframe animation after the advance
  phase must publish another browser animation-frame request.
- A fixed-height `overflow: scroll` block keeps its natural content height as
  DOM-owned scroll geometry while layout exposes the fixed client height.
  Paint keeps the box background stationary, translates its content by the
  persistent element offset, then applies a square or rounded subtree clip.
  Primary painted hits focus the innermost scroll container. Up/Down run on the
  tab worker and climb enclosing containers at boundaries before delegating to
  frame/root scrolling; this raw Node focus is retired with other DOM borrows.
- Structural DOM mutation is a synchronous generation boundary, distinct from
  ordinary render invalidation. Before a child array moves or a child is
  destroyed, mark layout/render dirty, retire the frame's display and DOM-keyed
  interaction state, clear tab accessibility/composited borrows, and retire
  active Browser draw/layer/display state under `Browser.lock`. Then destroy
  the mutating frame's complete layout dependency graph while the old DOM is
  still alive; the next full render rebuilds it. Schedule the replacement paint
  before any fallible mutation step. Preserve focus when the mutation root
  itself survives; clear it only for a removed descendant. After the child
  storage and parent pointers are final, run the paired completion callback
  synchronously so moved iframe identities are rebound and removed child-frame
  workers/callbacks are quiesced before JavaScript resumes.
- Content clicks walk the retained list in reverse paint order. A primary hit
  also runs the retained layout tree's parent-local point query; painted
  provenance remains authoritative for fragment gaps, glyph geometry, rounded
  corners, and rich controls, while the layout result provides provenance when
  a synthetic wrapper has none. Layout descent must invert live translations,
  apply element scroll at the owning block, and visit later siblings first
  instead of rebuilding per-object absolute rectangles. Keep this query on the
  serialized tab worker; UI-thread accessibility continues to consume its
  committed bounds snapshot. Positioned siblings use signed z-index followed
  by DOM index for both paint and reverse hit order; static elements remain in
  layer zero even when they declare z-index. A primary hit
  dispatches one click at the painted element and bubbles through its
  snapshotted DOM ancestry, even when no native control owns a default action;
  iframe events stay inside the child document. Resolve link/input/button
  default actions through stable JS handles after listeners return, and let
  `preventDefault` cancel the action without conflating it with
  `stopPropagation`. `link_bounds` and `iframe_bounds` may support
  layout-derived accessibility/coordinate bookkeeping, but must not select a
  click target; keep focus, accessibility, and fragment bounds intact.
- Rounded backgrounds are rounded hit targets, not their containing
  rectangles: corner misses continue through reverse paint order to visible
  content underneath. Keep an ordinary rounded element's complete paint group,
  plus input and rich-button payloads, under non-painting rounded hit-clip
  metadata so text, glyphs, and child commands cannot restore square click
  corners. Inputs and rich-button outer boxes also emit the same rounded
  primitive as ordinary block backgrounds. Preserve hit clips in retained-list
  clones and translation walks, including at fractional zoom.
- `scroll.zig` is the single source of truth for CSS scroll ranges and native
  scrollbar-thumb geometry. Clamping and drawing must use the same metrics.
  It also owns device-pixel interest-region geometry. The current tab surface
  caches at most four native window heights; its page-space start is valid only
  after a successful raster. Root scrolling inside that region is draw-only,
  while crossing either edge requests a new raster around the viewport.
  Resize, zoom, display-list retirement, and document geometry changes
  invalidate the region before any cached pixels can be reused.
- `scroll.zig` also owns the allocation-free, clock-based `ScrollAnimation`
  value. Up/Down on a page whose authored body computes
  `scroll-behavior: smooth` starts or retargets that value on the serialized
  tab worker; repeated keys accumulate against its pending destination. Each
  root step commits only the scalar offset, preserving draw-only scrolling
  inside the interest region. Focused overflow boxes, wheel/voice input,
  `auto`, and reduced-motion mode remain immediate and cancel a pending frame
  animation. Every queued scroll validates its originating tab under
  `Browser.lock` before touching state. Child-frame smooth scrolls currently
  recompose their iframe.
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
- After a document response and its redirects complete, X-Frame-Options is
  checked before an initial, dynamic, history, or existing child-frame
  navigation is recorded or installed. `DENY` rejects every ancestor chain;
  `SAMEORIGIN` requires the final response URL to match every live ancestor
  document origin and fails closed when an ancestor URL is unavailable.
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
  replace the content-derived height afterward. Visible overflow remains the
  default; `overflow: scroll` retains the content-derived height separately for
  element-local clamping and clips paint to the fixed box. Synthesized
  anonymous blocks always retain their automatic dimensions.
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
