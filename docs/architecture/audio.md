# Audio ownership and media elements

Zibra's first audio implementation supplies reusable PCM voices and basic
`<audio>` playback. The media-element behavior follows the
[WHATWG media model](https://html.spec.whatwg.org/multipage/media.html#media-elements),
with deliberately bounded loading and an explicit subset of the browser API.
Audio processing does not depend on DOM, JavaScript, layout, or SDL.

## Owners and data flow

| Owner | Responsibility |
| --- | --- |
| `BrowserSession.audio` (`src/media/audio.zig`) | Stable shared mixer, PCM budget, voice IDs and one lazy zoto output device |
| Session media runner | Serial complete-resource fetch/decode jobs; it waits on the separate networking runner |
| `src/media/decode.zig` | zigaudio decoding into independently owned interleaved f32 PCM |
| `Frame.audio_elements` (`src/media/element.zig`) | State, source revisions, cancellation tokens, source URLs and a voice ID per stable element handle |
| `src/browser/media.zig` | Source selection, policy, loading, numeric result delivery, controls and DOM reconciliation on the Tab worker |
| `src/script/media_bindings.zig` and `runtime/media.js` | Synchronous commands, copied snapshots, realm-local promises and event delivery |

The session and mixer must remain at stable addresses from first use through
shutdown. Interactive windows share their session's mixer. Standalone headless
sessions disable device creation; tests can instead select manual output and
advance it with `Engine.mix`. Native output currently uses the audited macOS
zoto driver. Other platforms can compile the core but reject native playback.

A clip owns its sample allocation. `Engine.add` transfers that ownership only
on success. A decoded clip also owns a reservation in the session PCM budget;
that reservation follows it through the pending completion, live voice, and
final free. Code using the engine directly must allocate clips with the engine
allocator and retire all clips/reservations before destroying the engine.

The output adapter owns a single continuous zoto reader/player. The reader
mixes independent voices into 48 kHz stereo f32 with per-voice pause, seek,
volume, mute, loop, mono duplication and linear sample-rate conversion. Mixing
allocates nothing and accesses voices under the mixer mutex. Removing a voice
synchronizes with rendering before freeing PCM. Device initialization has its
own mutex and never happens while the mixer mutex is held. Device teardown
removes the reader's player, joins/disposes zoto's context, then frees voices.

The native queue holds 32 ms of stereo PCM, and zoto's source buffer reserves
64 ms. The source reserve must cover a complete device-queue refill burst plus
scheduling headroom: the device worker can consume several buffers before the
source worker runs again. A smaller source buffer causes zoto to insert silence
even with a fully decoded clip. The PCM reader preserves partially consumed
samples across arbitrary byte reads; it has no dependency on the Tab event loop.

## Loading, identity and retirement

Each load snapshots owned target/referrer URLs, Referrer-Policy, a copied CSP
source list, cancellation token and `(window_id, document_generation,
element_handle, source_revision)`. A job never retains a Node, Frame,
JsRenderContext, or JavaScript value. Its queue envelope retains the Tab through
existing helper accounting, which also keeps its Browser and shared session
alive. The envelope and result have separate lifetimes: result delivery may
finish before the media-runner task returns.

The media runner synchronously bridges through the session networking runner,
then calls zigaudio on the returned bytes. Decoders and encoded bytes retire
before delivery; playback owns only PCM. A completion runs on the Tab worker,
re-resolves every numeric identity, and either transfers the clip or frees a
stale result. Queue rejection and allocation failures preserve exactly-once
cleanup. Source replacement cancels prior revisions. Cancellation prevents
queued work/redirects and is checked between decode chunks; it does not yet
interrupt an already-blocked network read or a codec call.

Initial discovery and mutation reconciliation happen after DOM storage settles.
JavaScript commands can also create state for detached `new Audio()` objects.
Moving an element preserves its handle/voice. Removing a previously attached
element pauses it during reconciliation; its detached wrapper can explicitly
play it again. Document replacement, child-frame navigation and Frame retirement
cancel all loads and remove all voices. Tab shutdown joins the producer, retires
voices promptly, then waits for accounted helpers. Session shutdown joins the
media runner before the networking runner, then disposes audio output. No worker
may outlive the allocators, measurement service or session that it borrows.

## Supported element behavior

- `new Audio(src)`, `HTMLAudioElement`, and `HTMLMediaElement` preserve canonical
  wrapper identity for parsed, created and relocated audio elements. Wrappers
  receive their media prototype once; retrieving a cached event target never
  requires rereading a native handle that a listener may have retired.
- `src` takes precedence over child `source` candidates. Candidates are tried
  in order, skipping unsupported MIME hints. `load()` restarts selection.
- `play()` returns a Promise; pause/load/source changes interrupt pending play.
  Audible playback requires prior trusted pointer/keyboard activation in that
  document. Muted or zero-volume playback is allowed; making it audible without
  activation pauses it. Autoplay uses the same gate and does not undo a pause.
- `currentTime`, duration, paused/ended, volume/muted/defaultMuted, loop, preload,
  autoplay, controls, currentSrc, error, network/ready states, `canPlayType`, and
  complete-resource buffered/seekable ranges are exposed.
- Metadata/readiness, play/playing/pause, seek, timeupdate, ended, volumechange,
  load/reset/error events are dispatched through existing node listeners and
  authored event handlers. Realm timers poll active state at 50 ms; ordinary
  timeupdate events are coalesced at roughly 250 ms of playback progress.
  Navigation retires these timers. Revision checks stop delivery after a
  listener changes the resource.
- Native controls are a focusable play/pause button, including Space/Enter
  activation and an accessible play/pause label. Other controls can use the
  JavaScript API. Audio without controls and audio fallback children occupy no
  rendered space.

## Resource and policy limits

This pass fetches and decodes the complete resource before publishing metadata
or playing. It does not require a codec seek API: once decoded, any supported
clip seeks by PCM position. `preload=none` defers this work until play/load;
`metadata` and `auto` both perform the bounded complete decode.

Limits are 32 MiB of encoded/decompressed response bytes, 128 MiB PCM per clip,
256 MiB PCM across voices and pending results, 64 tracked elements per document,
64 session voices/queued-or-running loads, and 16 candidates per element.
Allocator capacity growth, encoded buffers, codec scratch storage and URL
storage are additional to the PCM payload budget. Constrained fetches bypass
the ordinary response cache. HTTP redirects are checked before fetching each
target; file/data and decompressed HTTP bodies enforce the response byte limit.

Media checks `media-src`, falling back to `default-src`, even for same-origin
loads. Its conservative source-list subset supports `'self'`, `*`, schemes and
exact origins/paths; unknown/wildcard-host expressions do not grant access.
HTTPS documents cannot load HTTP media, and web documents cannot load local
files. Referrer-Policy and the session cookie transport are reused. Explicit
`crossorigin` attributes / `crossOrigin` property requests currently fail closed
because anonymous/credentialed CORS media fetching needs its own credentials
contract. Ordinary cross-origin
playback is allowed subject to CSP; no decoded samples are exposed to script.

## Extension points and current limitations

The engine accepts owned PCM independent of the element controller, so other
sound producers can reuse its voice/output lifetime without adopting DOM state.
Streaming should replace the complete clip with a bounded producer queue while
preserving numeric voice identity, cancellation, and submission ownership.
Web Audio, video, MediaSource, MediaStream, tracks, playback-rate changes,
`played` ranges, progress/stall semantics, permissions-policy autoplay delegation,
and full HTML media conformance are not implemented.

Linear resampling is a basic converter, not a high-quality band-limited filter.
Current time and ended measure submitted PCM, which can lead audible output by
the zoto/device buffer latency; a presentation clock belongs in the output
adapter when synchronization is required. Removing/seeking/pausing a voice
cannot retract PCM already submitted to that shared device buffer. These limits
must not be presented as sample-accurate browser media synchronization.
Zoto may refill by a complete source-buffer chunk, so its source queue can
approach twice the configured reserve. Including the native queue and reader
scratch, already-mixed audio can lead presentation by roughly 170 ms.

## Verification

Run `zig build test-browser -Dtest-filter=audio` for deterministic mixer,
codec, budget, policy, DOM/realm, source replacement and retirement coverage.
The PCM tests also check unaligned byte reads and device refill bursts through
the actual zoto mixer without a device or timing-dependent producer thread.
Run `zig build test-network -Dtest-filter=bounded` for body limits and redirect
policy checks. Tests drive output and completion/timer delivery explicitly.
`zig build test-wpt` also runs the full-browser audio-loading fixture, checking
metadata, control geometry, seeking events and autoplay rejection.
`tests/wpt/manifest-audio.yaml` selects five unchanged upstream audio cases.

On macOS, `ZIBRA_TEST_NATIVE_AUDIO=1 zig build test-browser
-Dtest-filter='audio native device lifecycle smoke'` opts into three real-device
startup/consumption/shutdown cycles using silence. This is separate from the
portable suite. Open [the audio fixture](../../tests/manual/audio.html) for
listening, controls, concurrent voices, seeking, and navigation checks. Broader
handoff checks follow [the testing guide](../testing.md).
