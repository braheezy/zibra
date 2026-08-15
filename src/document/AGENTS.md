# Document subsystem guide

This directory owns HTML parsing, DOM representation, CSS parsing, selector
matching, and style application.

Read [`../../docs/architecture-and-lifetimes.md`](../../docs/architecture-and-lifetimes.md)
before changing DOM storage, parser source-buffer ownership, style invalidation,
or selector/rule lifetime.

- Parser-created text, attributes, and CSS property slices borrow decoded
  document or stylesheet buffers. Preserve those buffers until all borrowers
  retire.
- `Node` children are stored by value in resizable arrays. Do not retain a
  `*Node` across structural mutation unless all consumers are invalidated or a
  stable identity scheme is in place.
- CSS rules own selector/map allocations while their property slices borrow the
  stylesheet. Move and retire rules with their source text as one generation.
- `<style>` element text is copied into the same owned stylesheet generation as
  decoded external CSS. Keep inline and linked sheets in DOM order, and make
  isolated inspection and interactive frame loading follow the same cascade.
- When adding a supported CSS property that has a shorthand, add its expansion
  to `CSSParser.putDeclaration`. Expand in source order for both stylesheet and
  inline declarations, preserve borrowed slices or static defaults, and test
  shorthand/longhand precedence in both directions.
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
