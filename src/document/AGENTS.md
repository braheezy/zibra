# Document subsystem guide

This directory owns HTML parsing, DOM representation, CSS parsing, selector
matching, and style application.

Read [`../../docs/architecture-and-lifetimes.md`](../../docs/architecture-and-lifetimes.md)
before changing DOM storage, parser source-buffer ownership, style invalidation,
or selector/rule lifetime.

- Parser-created tag names, text, undecoded attributes, and CSS property slices
  borrow document or stylesheet buffers. Attribute character references are
  decoded into `Element.owned_strings`; DOM text stays source-backed and
  escaped because layout decodes it exactly once. DOM dump serialization
  re-escapes decoded attribute values before quoting them. Preserve all source
  buffers until their remaining borrowers retire.
- Live HTML serialization emits attributes in deterministic name order, always
  quotes and escapes their current values, recursively emits ordinary element
  closing tags, and omits closing tags/children from void-element outer HTML.
  Copy source-backed DOM text verbatim so existing character references are
  not escaped a second time.
- `Node` children are stored by value in resizable arrays. Do not retain a
  `*Node` across structural mutation unless all consumers are invalidated or a
  stable identity scheme is in place.
- An attached iframe Element carries only its child window's numeric ID; that
  scalar moves safely with the by-value Node. The browser validates it against
  the current Tab registry before rebinding a Frame pointer. Detached iframe
  nodes may retain stale IDs, so no consumer may treat the scalar alone as a
  live browsing-context owner.
- Supported structural mutation must enter the dedicated synchronous host
  invalidation boundary after marking the target layout dirty and before child
  storage can move or retire. Keep ordinary render callbacks separate so
  style-only changes do not discard focus or hit/accessibility state.
- Before structural mutation destroys or relocates style fields, clear raw
  `ProtectedField` subscribers across the installed document. The required
  full style/layout pass rebuilds live dependency edges afterward.
- A detached retained subtree keeps its style maps but dirties every field and
  clears layout back-pointers. When it is reparented, inherited style reads
  register the current parent dependency before using a frozen field.
- CSS rules and `@keyframes` own their selector/frame/map containers while
  names and property slices borrow the stylesheet. Move and retire both parsed
  products with their source text as one generation.
- Conditional stylesheet parsing receives an explicit media environment.
  `max-width` compares its non-negative pixel limit against the viewport width
  in CSS pixels, inclusively, while `width` matches that value exactly modulo
  floating-point zoom normalization. Parser-only consumers without a viewport
  keep both features inactive. `forced-colors` accepts only `active` and `none`
  and follows the browsing context's accessibility setting. Retain stylesheet
  text so a browsing context can rebuild the filtered rule/keyframe generation
  when that environment changes.
- Concatenated tag/class selectors own a source-ordered `SelectorSequence` of
  atomic selectors, all of which must match the same element. Sequence
  specificity is the sum of its members.
- `:focus-visible` is a dynamic class-specificity selector and may stand alone
  or join a tag/class sequence. It matches only when both `Element.is_focused`
  and the Tab-installed `Element.is_focus_visible` heuristic snapshot are set.
  Focus transitions must dirty the element before styling so selector queries,
  author rules, and the native focus ring observe the same generation.
- Descendant selectors own a flat, source-ordered list of simple selectors.
  Matching callers must pass ancestors from the document root through the
  immediate parent so matching remains one O(n + d) backward walk.
- `:has(...)` owns its anchor and strict-descendant selector components. Style
  and script queries must prepare an ephemeral post-order `HasMatchCache` before
  matching: preprocessing is O(HN), then each fixed relational selector is an
  average-O(1) lookup per element. Because descendant changes affect ancestors,
  selector-relevant mutation hooks must dirty the changed element and its
  ancestor chain before the next style pass.
- `<style>` element text is copied into the same owned stylesheet generation as
  decoded external CSS. Keep inline and linked sheets in DOM order, and make
  isolated inspection and interactive frame loading follow the same cascade.
- `Element.script_started` is document-lifetime execution identity. It moves
  with a detached/re-attached node and prevents a previously queued classic
  script from running again; newly parsed or created script elements start
  unset. Structural mutation causes the owning frame to rescan attached
  resources after the JavaScript host call returns.
- `collectDocumentTitle` copies the first `title` element's descendant text
  into an owned sentinel-terminated slice; native window state must never
  retain the DOM's source-backed text slices.
- `Element.is_visited` is a non-owning browser-session annotation. Link URL
  storage stays in the session owner; layout may inspect the annotation only
  through the current document's synchronous parent chain during paint.
- Checkbox state is represented only by presence or absence of the borrowed
  `checked` attribute entry. Activation may insert the static empty value or
  remove that entry; it must not replace the control's independent `value`.
  Layout and successful-control serialization read the same attribute state.
- Input-type comparisons are ASCII case-insensitive and use the normalized
  `Element.inputType` view. Hidden and password inputs keep their real `value`
  attribute in the DOM: layout suppresses hidden controls and masks password
  paint without replacing or duplicating that submission value.
- `Element.canvas` owns a heap-stable `document/canvas.zig` backing object only
  after `getContext("2d")`. The pointee may not move because its z2d Context
  borrows the embedded Surface. Width/height content attributes select the
  bitmap dimensions (300x150 defaults) and a resize clears native drawing
  state; DOM child-array relocation moves only the owning pointer.
- `background_image.zig` parses the supported single-image `url(...)` and
  background-size grammar independently of networking and paint. After final
  computed style selects a URL, the Element owns both an attempted-source copy
  and optional decoded `ImageData`; blocked/broken attempts deliberately keep
  the source key so an unchanged restyle does not fetch forever. Structural
  removal releases that resource with the rest of the Element.
- `object_fit.zig` parses the five basic replaced-image fit modes and resolves
  centered destination plus fractional source-crop geometry without depending
  on layout, networking, or raster state. Preserve fractional crop edges: an
  integer crop visibly distorts small images with a mismatched aspect ratio.
- `Element.image_data == null` means an HTML image has not reached a terminal
  load state. The browser treats only an ASCII case-insensitive
  `loading=lazy` as deferred; missing, invalid, and `eager` values load during
  resource discovery. Success and broken-image fallback both install owned
  `ImageData`, preventing repeated fetches on later animation frames.
  `ImageData.is_broken` distinguishes synthetic fallback pixels from decoded
  content without changing ownership; layout consumes that status together
  with the element's live `alt` attribute.
- `focus.zig` is the canonical HTML focusability policy shared by layout,
  keyboard traversal, and JavaScript. Programmatic focus accepts an explicit
  negative `tabindex`, while sequential focus rejects it; hidden inputs,
  disabled controls, and `contenteditable=false` are rejected by both. Layout
  visibility remains a separate, current-generation bounds check.
- A `button` start tag implicitly closes an active button even through
  intervening flow descendants, so malformed nested-button source produces
  sibling controls. Other descendants, including non-conforming interactive
  input and anchor elements, remain in the button's DOM subtree for layout and
  closest-painted-target activation.
- `inspection.Page.load` returns its DOM by value. Call
  `Page.repairParentPointers` after the returned page reaches its final address
  and before layout/paint performs any ancestry walk.
- When adding a supported CSS property that has a shorthand, add its expansion
  to `CSSParser.putDeclaration`. Expand in source order for both stylesheet and
  inline declarations, preserve borrowed slices or static defaults, and test
  shorthand/longhand precedence in both directions.
- CSS declaration maps store borrowed values together with declaration-local
  `!important` metadata. Preserve importance through shorthand expansion and
  compare cascade priority per property: selector priority plus 10,000 for
  important declarations, with later declarations winning exact ties.
- Declaration value scanning stops only at top-level semicolons/braces;
  preserve quotes, escapes, and parenthesis depth so `url(data:...;...)` and
  other supported CSS functions remain one borrowed value.
- Keep the computed-style property table and inherited-property defaults in
  sync. A computed `font-family` borrows either its declaration or inherited
  parent slice; rendering resolves the supported family/fallback list without
  retaining a new borrowed value.
- `width` and `height` are non-inherited computed properties. Their default is
  `auto`; layout resolves non-negative `px`, `em`, and percentage lengths
  against an explicit font-size/containing-block context and keeps the
  borrowed computed-value slice in the style map. Replaced images use a
  supported CSS dimension before the corresponding HTML width/height fallback.
- `background-image` and `background-size` are non-inherited and default to
  `none` and `auto`. Their declaration values remain borrowed computed-style
  slices; only a finally selected supported URL receives an independent
  Element-owned resource identity.
- `object-fit` is non-inherited and defaults to `fill`. The supported modes are
  `fill`, `contain`, `cover`, `none`, and `scale-down`; invalid values fall
  back to `fill` in the layout value-validation subset.
- `aspect-ratio` is non-inherited and defaults to `auto`. Replaced-element
  layout accepts a positive number, a positive numerator/denominator pair, and
  the `auto || <ratio>` fallback form; invalid and zero ratios behave as
  `auto`. The computed map retains the borrowed declaration string, while the
  pure used-size parser lives in `browser/render/replaced_sizing.zig`.
- `zoom` is non-inherited and defaults to `1`. Layout accepts positive numbers
  and percentages, treats zero as one for web compatibility, and multiplies
  used fixed lengths through the ancestor chain. Invalid/negative values fall
  back to one in this simplified value-validation model; auto and percentage
  dimensions remain unaffected.
- Each Element owns a property-keyed tagged transition map. Numeric entries
  currently drive opacity, color entries interpolate RGBA channels together,
  pixel entries preserve the `px` unit for width/height, and transform entries
  interpolate both axes of a parsed `translate(...)`. All store their timing
  function and apply it to normalized frame progress before interpolation.
  `length.zig` owns the supported non-negative `px`, `em`, and percentage
  grammar plus context-based CSS-pixel resolution; `easing.zig` owns the
  timing-function parser and cubic Bezier solver. Opacity's computed-style
  string borrows a fixed buffer embedded in that same Element; layout reads
  animated colors and dimensions directly from the tagged map.
- `css_animation.zig` parses the supported single-animation shorthand: named
  duration, shared easing functions, integer/infinite iterations, and
  normal/alternate direction. An Element's `CssAnimationState` identifies the
  entries in the interpolation map that came from its named `@keyframes` rule;
  typed endpoints own no stylesheet slices. Preserve endpoint frames and
  mirror the timing function when reversing alternate cycles, and restore the
  underlying computed property after a finite animation without overwriting
  that property during playback.
- Element-local overflow scroll offsets and client/content heights are scalar
  DOM state. Layout republishes and clamps their geometry; input may change
  only the offset between layouts. Structural mutation consumers must retire
  any focused raw Node before its by-value child storage moves.
- `filter` is non-inherited and defaults to `none`. Layout currently accepts a
  single non-negative `blur()` pixel length (or unitless zero); unsupported
  filter functions and chains have no effect.
- `display` is non-inherited and defaults to `inline`. HTML block defaults live
  in the user-agent stylesheet; layout reads the borrowed computed value.
- `position` and `z-index` are non-inherited and default to `static` and `0`.
  The layout painter accepts signed integer z-index values only when position
  is non-static; invalid values retain the zero paint layer.
- `scroll-behavior` is non-inherited and defaults to `auto`. The tab worker
  reads the authored body element's computed value when an arrow-key viewport
  scroll begins; descendants do not opt the viewport into smooth scrolling.
- Keep parser output deterministic: the `--dump-dom` golden test is the first
  inspection contract for this pipeline stage.

Add parser-level unit tests for grammar/ownership changes and a manual HTML
fixture whenever visible browser behavior changes.
