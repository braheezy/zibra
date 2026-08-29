# Document subsystem guide

This directory owns HTML parsing, DOM representation, CSS parsing, selectors,
computed style, and pure helpers for document-backed rendering features.

Read [document and rendering contracts](../../docs/architecture/document-and-rendering.md)
before changing DOM storage, source buffers, mutation, style invalidation, or
layout callbacks. Read
[JavaScript and accessibility contracts](../../docs/architecture/javascript-and-accessibility.md)
for exported Node handles, focusability, canvas wrappers, or script-visible
behavior. Navigation-owned stylesheet/resource generations are documented in
[navigation and network](../../docs/architecture/navigation-and-network.md).

## Ownership rules

- Parser-created text, lowercase names, undecoded attributes, CSS names, and
  property values generally borrow document or stylesheet buffers. Element
  decoded strings, images, canvas pointers, animations, and detached subtree
  resources are explicit owners. Do not retire backing text first.
- Children are Node values in resizable arrays. Never retain a child `*Node`
  across structural mutation unless the synchronous mutation transaction
  invalidates or rebinds every consumer before control escapes.
- `fixParentPointers` must also rebind computed-style field owners because
  inherited invalidation callbacks retain those owner pointers.
- Rules, named keyframes, and the source text they borrow move and retire as
  one generation. Stage a complete replacement before dropping the prior one.
- Live HTML serialization reads current attributes/tree, sorts attribute names,
  quotes/escapes values, preserves source-backed text without double escaping,
  and omits children/closing tags for void elements.

## Mutation and invalidation

- Structural mutation enters the dedicated host boundary after staging
  fallible owners and before child storage moves. Ordinary render callbacks are
  separate and must not discard interaction state for a style-only change.
- General mutation clears current style subscriber maps while endpoints are
  alive, dirties the installed style tree, and rebuilds layout. The verified
  insertion-only exception preserves endpoints and immediately rebinds matched
  layout pointers.
- Elements install separate synchronous layout and paint callbacks on the
  nearest persistent layout owner. Clear both when that owner retires.
- Each Element's `has_dirty_style_descendants` permits clean subtree skipping.
  Raise it for selector changes and inherited notifications; clear only after
  requested descendants finish successfully.
- Detached retained subtrees keep style maps but dirty every field and clear
  layout back-pointers. Reattachment registers inherited dependencies against
  the new parent.
- Attribute/inline-style changes that affect relational selectors dirty the
  changed Element and ancestors before the next style pass.

## CSS rules

- Declaration values borrow the parsed source. Preserve quotes, escapes,
  comments, and parenthesis depth while scanning; stop only at top-level
  separators.
- Shorthand expansion happens in source order and preserves declaration-local
  `!important`. Add precedence tests in both shorthand/longhand directions.
- Keep computed-property defaults and inheritance policy synchronized with
  parser support. Non-inherited properties retain their borrowed computed
  string; used-value validation belongs in the focused helper/layout owner.
- Conditional parsing receives an explicit media environment. Root and iframe
  callers must rebuild source-backed rule/keyframe generations when width,
  zoom, or forced-colors environment changes.
- Descendant selectors receive ancestors in document-root-to-parent order.
  `:has` caches are ephemeral synchronous borrows and selector-relevant
  changes invalidate ancestor matches.
- Dynamic `:hover` and `:focus-visible` state is installed by the serialized
  Tab worker and must dirty style before matching.

## Focus, controls, canvas, and images

- `focus.zig` is the canonical intrinsic programmatic/sequential focusability
  policy. Layout visibility is a separate current-generation check.
- Checkbox state is only the presence of `checked`; hidden/password inputs keep
  one real DOM value. Never introduce parallel widget submission state.
- Canvas backing is lazily heap-stable because z2d Context points into it.
  Dimension assignment resets pixels and drawing state even when unchanged.
- HTML image null data means nonterminal load state; success and broken fallback
  install owned terminal ImageData. Background resource identity is selected
  only after cascade and owned by the Element.
- `background_image.zig`, `object_fit.zig`, `length.zig`, `easing.zig`, and
  related helpers stay pure of Browser/network/native state.

## Parser structure

Explicit `html`, `head`, and `body` starts create nodes that implicit-tag logic
would otherwise create; do not process the same token through both paths.
Nested button starts implicitly close the active button, while other
descendants remain within the current button for layout and activation.

The document pipeline is split by ownership and algorithm boundaries:

- `dom.zig` owns `Node`, `Element`, and `Text` representation, Element-backed
  resources, parent/style-owner rebinding, and DOM invalidation callbacks.
- `html_parser.zig` is the stateful tokenizer/tree builder. It borrows the
  decoded HTML buffer and receives DOM types plus final parent-pointer repair
  through a comptime boundary, so it does not import the compatibility facade.
- `html_serialization.zig` is a generic leaf that traverses the live DOM,
  escapes attributes, and applies void-element rules without owning nodes or
  source buffers.
- `css_syntax.zig` is a pure source-buffer scanner for CSS comments, escapes,
  strings, and structural delimiters; `css_properties.zig` is the shared
  static registry of computed longhand names and defaults.
- `animation.zig` owns pure CSS transition/keyframe value objects stored by
  Elements. It does not decide whether an animation dirties compositor,
  paint, or layout; the Tab driver owns that phase decision.
- `style_application.zig` owns computed-property defaults, cascade,
  inheritance, animation-track updates, and the style-pass algorithm behind a
  narrow comptime DOM/callback interface. It never owns a Node or layout
  object.
- `style.zig` binds that generic style application to `dom.zig` and exports
  Zibra's concrete style-pass API.
- `parser.zig` is the stable compatibility entry point. It re-exports the DOM,
  HTML parser, serialization, animation, and style APIs for existing callers;
  it is not an additional owner and must stay an acyclic, logic-free facade.

`inspection.Page.load` returns the root by value. Repair parent pointers after
the returned page reaches its final address before any ancestry-dependent
style/layout/paint operation.

Add new grammar/data owners in focused modules rather than putting logic in
the compatibility entry point. Avoid facade cycles or splitting methods away
from the DOM/style invariants they maintain.

## Verification

Run `zig build test-document` while iterating. Run `zig build test-pipeline`
for exact style/layout/display output and `zig build test-dump-dom` for parser
serialization. Before handoff run `zig build check`; use native macOS
screenshots only for final pixel behavior. Add/update a primary fixture in the
[manual catalog](../../tests/manual/README.md) for visible interaction.
