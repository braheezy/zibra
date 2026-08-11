# Browser subsystem guide

This directory owns the process `Browser`, tabs/frames, navigation orchestration,
the compositor, SDL integration, layout, font resources, and chrome.

Read [`../../docs/architecture-and-lifetimes.md`](../../docs/architecture-and-lifetimes.md)
before changing `root.zig`, `tab.zig`, `render/`, or browser task scheduling.

- `root.zig` owns SDL, shared networking state, active render snapshots, and
  shutdown order. Browser-side snapshot retirement must precede document or
  tab destruction.
- `tab.zig` owns frames, document generations, task serialization, and helper
  quiescence. Queued or detached work must carry a stable document identity,
  not a borrowed frame pointer.
- `render/layout.zig` and `render/font.zig` borrow DOM/image state and own
  layout/font resources. `FontManager` owns canonical RGBA glyph bitmaps;
  display-list `Glyph` values borrow those bytes, and `pixel_mode` tells paint
  whether to tint an alpha mask or preserve native color. Layout must retire
  before DOM, and display snapshots must retire before `FontManager`.
- `scroll.zig` is the single source of truth for CSS scroll ranges and native
  scrollbar-thumb geometry. Clamping and drawing must use the same metrics.
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
- Soft hyphens are invisible discretionary breaks. Track every candidate in
  the current word, use the latest one whose visible hyphen fits, and transfer
  the suffix to the next line without duplicating owning inline payloads.
- Keep browser rendering work and isolated inspection modes separate. A DOM
  dump must not construct `Browser` merely to reuse a convenience method.

For changed browser behavior, add a deterministic manual fixture and run the
relevant unit, DOM-dump, and macOS screenshot checks from the root guide.
