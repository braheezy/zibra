# Network subsystem guide

`url.zig` owns URL parsing/resolution, HTTP requests, cookies, response
decoding, and file/data/about resource handling.

Read [`../../docs/architecture-and-lifetimes.md`](../../docs/architecture-and-lifetimes.md)
before changing URL or response ownership.

- `Url` is logically move-only despite Zig value-copy syntax. Use `Url.clone`
  whenever two independently live owners are needed.
- `HttpResponse.body` ownership depends on scheme: HTTP/file are allocated;
  data/about borrow URL/static storage. Preserve or improve this boundary—do
  not free by guesswork at a distant caller.
- `Url.fetchBody` is browser-independent. Keep it free of SDL, tabs, and
  renderer concerns so inspection commands can reuse it.
- Add data/file tests for ownership changes; use a local fixture/server for
  HTTP, redirects, cookies, compression, or CSP behavior.
