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
- Browser-owned requests enter the session networking task runner before
  calling the synchronized URL transport. The browser-free inspection CLI is
  the intentional direct-fetch exception because it owns no BrowserSession.
  A document's linked-resource batch is one queued network task whose joined
  transport workers use the low-level synchronized API; this preserves request
  parallelism without letting tab code bypass the networking owner.
- Zig's HTTP client exposes TLS handshake and certificate-verification setup
  failures as `TlsInitializationFailed`. Keep that classification at the URL
  boundary; document navigation may turn it into browser UI, while subresource
  fetches must continue returning the transport error to their caller.
- Cache hits must preserve the normal fetch ownership contract by returning
  caller-owned body and header copies, and must reproduce response metadata
  such as Referrer-Policy and X-Frame-Options. X-Frame-Options is parsed into
  scalar `DENY`/`SAMEORIGIN` policy at the HTTP boundary; obsolete
  `ALLOW-FROM` and unknown values are ignored. Interactive cache, cookie, and HTTP client state
  belongs to the shared `BrowserSession`; standalone screenshot browsers own
  their session. Zig's client opens connections thread-safely. The session's
  network mutex protects cookie/cache lookup, copying, eviction, and mutation,
  but must not cover the complete round trip or parallel subresources become
  serialized. Copy a Cookie header while locked before giving it to a request.
- Referer generation borrows the source URL only for the synchronous request,
  omits its fragment, and applies the source document's `no-referrer` or
  `same-origin` policy. Policy suppression must not erase the request context:
  SameSite cookie checks still receive the unsuppressed source URL.
- A computed CSS background URL is an ordinary image subresource: resolve it
  strictly against the containing document, apply that Frame's CSP and
  Referrer-Policy, and preserve the same HTTP/file versus data/about body
  ownership split as `<img>`. Discovery belongs after cascade, outside the URL
  layer, so an unused declaration never reaches transport.
- Cross-origin XHR uses the explicit Origin-bearing fetch path. That path
  bypasses the ordinary response cache, still selects target-host cookies, and
  returns an owned `access_control_allow_origin` header for the XHR policy
  check. Navigation and ordinary subresources never request or own that field.
- The tutorial cookie jar owns one entry per normalized host. Server
  Set-Cookie and script assignments share one parser that retains the raw
  parameter string and derives SameSite/HttpOnly/Expires state. Absolute
  expiration uses the real clock; every HTTP or script read lazily removes an
  expired owning entry. HttpOnly entries still supply the HTTP Cookie header
  but are hidden from, and immutable through, `document.cookie`; script cannot
  create an HttpOnly entry.
- Add data/file tests for ownership changes; use a local fixture/server for
  HTTP, redirects, cookies, compression, or CSP behavior.
