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
- CSS rules own selector/map allocations while their property slices borrow the
  stylesheet. Move and retire rules with their source text as one generation.
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
- `display` is non-inherited and defaults to `inline`. HTML block defaults live
  in the user-agent stylesheet; layout reads the borrowed computed value.
- Keep parser output deterministic: the `--dump-dom` golden test is the first
  inspection contract for this pipeline stage.

Add parser-level unit tests for grammar/ownership changes and a manual HTML
fixture whenever visible browser behavior changes.
