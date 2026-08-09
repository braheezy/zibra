# Test and fixture guide

`tests/manual/` contains minimal human-readable regression pages. Put a short
"How to verify" comment at the top of each page and make the expected result
visible and deterministic.

`tests/golden/` contains committed deterministic outputs. Update a golden only
after confirming that the behavioral change is intentional; do not use a golden
update to hide a regression.

Current checks:

- `zig build test` — unified Zig unit suite.
- `zig build test-dump-dom` — isolated HTML parse/DOM-dump output, including
  literal `about:blank`, malformed-navigation recovery, and unsupported-scheme
  recovery.
- `zig build test-screenshot` — native macOS rendering output.

Choose the narrowest check that covers the pipeline stage under change. A DOM
or parser regression should normally add a DOM dump or unit fixture before a
full screenshot fixture.
