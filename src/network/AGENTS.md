# Network subsystem guide

`url.zig` owns URL parsing/resolution, HTTP requests, cookies, response
decoding, cache integration, and file/data/about resource handling.
`cache.zig` owns decoded browser-session response entries and the supported
`Cache-Control` policy parser.

Read [`../../docs/architecture-and-lifetimes.md`](../../docs/architecture-and-lifetimes.md)
before changing URL or response ownership.

- `Url` is logically move-only despite Zig value-copy syntax. Use `Url.clone`
  whenever two independently live owners are needed.
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
