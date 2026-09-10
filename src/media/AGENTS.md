# Audio core guide

Read [audio ownership](../../docs/architecture/audio.md) before changing voices,
clip ownership, decoding, output, limits or element state. Browser orchestration
belongs in `../browser/media.zig`; this directory must not retain DOM, Frame or
JavaScript values. Source URL policy depends only on the network facade.

The session and PCM budget have stable addresses. Clips transfer ownership only
on successful adoption, including their budget reservation. All decode/output
allocations use the session's thread-safe allocator. Rendering allocates nothing.
Never open/join a device while holding the mixer mutex.

`time_ranges.zig` owns normalized played history. Reserve capacity before
play/seek under the voice lock; merging during output must not allocate.
`controls.zig` contains copied UI state and scalar focus/drag values; geometry
and paint belong to the browser render helper, and input to its media controller.

Run `zig build test-browser -Dtest-filter=audio` while iterating. Native output
is opt-in; see the architecture document for the silent device smoke test and
manual fixture. Use the repository verification guide before handoff.
