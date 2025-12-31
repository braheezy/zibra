# Optimizations

Ideas to reduce startup latency and improve render responsiveness.

## Fonts
- Lazy-load fonts: load only the primary latin font at startup, defer CJK/emoji/monospace until glyphs from those ranges are encountered.
- Cache resolved font paths between runs to avoid repeated filesystem scans.
- Cache font handles across tabs and reload only when size/style changes.
- Consider reducing the number of default fonts loaded during startup (load on-demand).

## Rendering and Layout
- Defer layout/paint until the first content is available; avoid layout for about:blank if immediately replaced.
- Reuse display lists when only scroll changes (already mostly done) and avoid rebuilding when toggling non-layout settings.
- Batch display list allocations to reduce allocator churn (reuse buffers).

## I/O and Resource Loading
- Parallelize CSS/JS fetch and parsing with layout preparation where safe.
- Add a small startup cache for local file reads to avoid repeated disk access.

## Instrumentation
- Add timing logs for font discovery, layout, paint, and first draw to pinpoint hot spots.
