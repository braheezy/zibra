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
- Concatenated tag/class selectors own a source-ordered `SelectorSequence` of
  atomic selectors, all of which must match the same element. Sequence
  specificity is the sum of its members.
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
- Keep the computed-style property table and inherited-property defaults in
  sync. A computed `font-family` borrows either its declaration or inherited
  parent slice; rendering resolves the supported family/fallback list without
  retaining a new borrowed value.
- `width` and `height` are non-inherited computed properties. Their default is
  `auto`; layout currently resolves only non-negative pixel lengths and keeps
  the borrowed computed-value slice in the style map.
- Each Element owns a property-keyed tagged transition map. Numeric entries
  currently drive opacity, color entries interpolate RGBA channels together,
  pixel entries preserve the `px` unit for width/height, and transform entries
  interpolate both axes of a parsed `translate(...)`. All store their timing
  function and apply it to normalized frame progress before interpolation.
  `length.zig` owns the supported non-negative pixel grammar; `easing.zig` owns
  the timing-function parser and cubic Bezier solver. Opacity's computed-style
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
- Keep parser output deterministic: the `--dump-dom` golden test is the first
  inspection contract for this pipeline stage.

Add parser-level unit tests for grammar/ownership changes and a manual HTML
fixture whenever visible browser behavior changes.
