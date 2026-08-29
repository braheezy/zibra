# Network subsystem guide

`url.zig` owns parsed/resolved URL identity and remains the public compatibility
facade for network consumers. It re-exports the existing response, cookie, and
cache types/helpers, and its `Url.fetchBody*` methods delegate to the internal
transport seam. Code outside `src/network/` should keep importing this facade
instead of coupling itself to the implementation leaves.

The implementation leaves have separate ownership responsibilities:

- `response.zig` defines response metadata plus Referrer-Policy,
  X-Frame-Options, CORS, and UTF-8 decoding helpers. A response value does not
  by itself identify which of its slices are owned.
- `cookie.zig` defines owning cookie entries and the transactional parser and
  selection rules. The surrounding `BrowserSession` jar owns normalized host
  keys and entry lifetimes.
- `cache.zig` owns decoded browser-session response entries, their URL keys,
  retained metadata, and the supported `Cache-Control` policy parser.
- `transport.zig` performs browser-independent scheme dispatch, HTTP, redirect,
  cache, and cookie coordination. It borrows the supplied client/jar/cache and
  is parameterized by the URL type and URL-policy callbacks so it never imports
  `url.zig` back into itself.

Keep the dependency direction acyclic: the facade delegates to transport;
transport depends on the response, cookie, and cache leaves; response shares
the scalar policy types defined by cache. `transport.fetchBodyInternal` is an
internal implementation seam, not a replacement public fetch API.

Read [navigation and network contracts](../../docs/architecture/navigation-and-network.md)
before changing URL, response, request, cache, cookie, or session ownership;
read [threads and shutdown](../../docs/architecture/threads-and-shutdown.md)
before changing networking dispatch or teardown.

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
  data/about borrow URL/static storage. HTTP/cache results also return owned
  `csp_header` copies when present, and Origin-bearing HTTP requests may return
  an owned `access_control_allow_origin`; scalar policy/status fields own no
  storage. Preserve or improve this boundary—do not free by guesswork at a
  distant caller.
- The `Url.fetchBody*` compatibility boundary is browser-independent. Keep it
  free of SDL, tabs, and renderer concerns so inspection commands can reuse it.
  Caching and synchronization are explicitly supplied dependencies;
  inspection callers may opt out, while browser callers select a synchronized
  variant through `resource_loader.Loader`.
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
- `HttpCache.lookup` returns borrowed entry data that is valid only until cache
  mutation/deinit. The transport must copy a hit's body, headers, and final URL
  while locked before returning through the normal fetch contract, and must
  reproduce scalar metadata such as Referrer-Policy and X-Frame-Options.
  X-Frame-Options is parsed into scalar `DENY`/`SAMEORIGIN` policy at the HTTP
  boundary; obsolete `ALLOW-FROM` and unknown values are ignored. Interactive
  cache, cookie, and HTTP client state belongs to the shared `BrowserSession`;
  standalone screenshot browsers own their session. Zig's client opens
  connections thread-safely. The session's network mutex protects
  cookie/cache lookup, copying, eviction, and mutation, but must not cover the
  complete round trip or parallel subresources become serialized. The
  cookie-layer request selection is borrowed; copy its header value while
  locked before giving it to a request.
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
- The tutorial cookie jar owns one entry per normalized host. Each
  `cookie.Entry` owns its value and optional raw parameter string; the jar owns
  the host key. Server Set-Cookie and script assignments share one parser that
  derives SameSite/HttpOnly/Expires state. Absolute expiration uses the real
  clock; every HTTP or script read lazily removes an expired owning entry.
  `cookieForScript` returns an independent allocation, while the leaf
  `cookieForRequest` result borrows its entry and must be snapshotted under the
  network lock. HttpOnly entries still supply the HTTP Cookie header but are
  hidden from, and immutable through, `document.cookie`; script cannot create
  an HttpOnly entry.
- Add data/file tests for ownership changes; use a local fixture/server for
  HTTP, redirects, cookies, compression, or CSP behavior. Run
  `zig build test-network` while iterating and `zig build check` before handoff.
