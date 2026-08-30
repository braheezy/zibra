# Test and fixture guide

Read the repository [testing guide](../docs/testing.md) before adding or
changing coverage. The complete primary-page inventory lives in the
[manual fixture catalog](manual/README.md); do not duplicate it here.

## Local rules

- Put deterministic unit coverage in the matching `src/tests/` module or next
  to a pure owner. Force the transition, interleaving, cleanup, or ownership
  boundary being tested; do not use process exit or arbitrary sleeps as proof.
- `tests/golden/` contains committed exact output. Inspect and justify a golden
  difference before updating it. Never regenerate a golden merely to make a
  failure pass.
- A primary page in `tests/manual/` starts with a concise `How to verify`
  comment and makes success/failure visible and deterministic. Support child,
  target, stylesheet, script, image, and server files are opened through that
  primary page and need not repeat its instructions.
- Update `manual/README.md` when adding, removing, renaming, or materially
  changing a primary fixture.
- Prefer a portable DOM/style/layout/display-list assertion for semantics and a
  native screenshot only for the final pixels. Platform fonts make exact image
  comparisons unsuitable as the sole cross-platform proof.
- Use local deterministic servers for HTTP behavior. Tutorial server tests
  should avoid binding a public port.

## Commands

Focused steps are `test-document`, `test-render`, `test-network`,
`test-script`, and `test-browser`. Broader steps include:

- `zig build check` — portable aggregate;
- `zig build test-pipeline` — exact box-model and nested-zoom
  style/layout/display-list goldens;
- `zig build test-dump-dom` — DOM CLI output;
- `zig build test-wpt-runner` — WPT manifest-runner protocol and failure paths;
- `zig build test-wpt` — local headless WPT PASS/TIMEOUT protocol fixtures;
- `zig build test-screenshot` — native macOS visual goldens;
- `zig build test-server` — tutorial server unittest;
- `zig build test-docs` and `zig build test-format` — repository documentation
  links and formatting. `test-docs` excludes the vendored
  `tests/wpt/upstream` submodule, which follows WPT's own link/build rules.

Choose the narrowest step while iterating, then run the complete checks
appropriate to the changed owner before handoff. Report checks that were not
available on the current platform.

## Baselines

`manual/acid1-box-model.html`, `manual/css-zoom.html`, and
`manual/dump-pipeline.html` are broad integration baselines. Their manual
appearance alone is not an automated compatibility claim. Convert discovered
regressions into focused unit or pipeline goldens, retaining native screenshots
where exact integrated paint matters.
