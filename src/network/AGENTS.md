# Network subsystem guide

`url.zig` owns URL parsing/resolution, HTTP requests, cookies, response
decoding, cache integration, and file/data/about resource handling.
`cache.zig` owns decoded browser-session response entries and the supported
`Cache-Control` policy parser.

Read [`../../docs/architecture-and-lifetimes.md`](../../docs/architecture-and-lifetimes.md)
before changing URL or response ownership.

- `Url` is logically move-only despite Zig value-copy syntax. Use `Url.clone`
  whenever two independently live owners are needed.
- Relative references are resolved by Ada against the complete base href so
  query and fragment components follow URL semantics. `Url.fragment` and
  `Url.sameDocument` return borrowed views/comparisons; do not retain their
  backing slices beyond the owning URL. HTTP requests omit fragments, while
  final redirect and cache-hit URLs inherit the requested fragment when the
  destination did not supply one.
- Use `Url.initForNavigation` and `Url.resolveForNavigation` for targets that
  replace a document. They preserve allocation failures but normalize URL
  syntax/payload errors and unsupported schemes to `about:blank`.
  Subresources should continue using strict `init`/`resolve` and handle errors
  without replacing the containing document.
- `HttpResponse.body` ownership depends on scheme: HTTP/file are allocated;
  data/about borrow URL/static storage. Preserve or improve this boundary—do
  not free by guesswork at a distant caller.
- `Url.fetchBody` is browser-independent. Keep it free of SDL, tabs, and
  renderer concerns so inspection commands can reuse it. Caching is an
  explicitly supplied dependency; inspection callers may opt out.
- Cache hits must preserve the normal fetch ownership contract by returning
  caller-owned body and header copies. Cache entries remain Browser-owned and
  are protected by the Browser HTTP mutex.
- Add data/file tests for ownership changes; use a local fixture/server for
  HTTP, redirects, cookies, compression, or CSP behavior.
