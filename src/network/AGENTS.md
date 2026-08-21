# Network subsystem guide

`url.zig` owns URL parsing/resolution, HTTP requests, cookies, response
decoding, cache integration, and file/data/about resource handling.
`cache.zig` owns decoded browser-session response entries and the supported
`Cache-Control` policy parser.

Read [`../../docs/architecture-and-lifetimes.md`](../../docs/architecture-and-lifetimes.md)
before changing URL or response ownership.

- `Url` is logically move-only despite Zig value-copy syntax. Use `Url.clone`
  whenever two independently live owners are needed.
- Use `Url.toOwnedString` for canonical URL keys that must outlive a borrowed
  `Url` or exceed a fixed formatting buffer. The caller owns that serialization;
  `view-source:` identity remains part of it.
- Navigation normalization accepts the browser-owned `about:bookmarks` page in
  addition to `about:blank`. Network-level `aboutRequest` remains static;
  `Browser.fetchNavigationDocument` generates the session-specific page and
  returns its body with explicit ownership.
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
- Zig's HTTP client exposes TLS handshake and certificate-verification setup
  failures as `TlsInitializationFailed`. Keep that classification at the URL
  boundary; document navigation may turn it into browser UI, while subresource
  fetches must continue returning the transport error to their caller.
- Cache hits must preserve the normal fetch ownership contract by returning
  caller-owned body and header copies. Interactive cache, cookie, and HTTP
  client state belongs to the shared `BrowserSession` and is protected by its
  dedicated network mutex; standalone screenshot browsers own their session.
- Add data/file tests for ownership changes; use a local fixture/server for
  HTTP, redirects, cookies, compression, or CSP behavior.
