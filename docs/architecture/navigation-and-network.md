# Navigation, resources, URL, and network contracts

This document is authoritative for document replacement, Frame history,
resource loading, URL/response ownership, cookies, cache policy, referrers,
CORS, CSP, and embedding policy. Read it before changing navigation or
`src/network/`.

## Network implementation boundary

`src/network/url.zig` is both the owner of parsed URL identity and the stable
compatibility facade for existing consumers. Code outside `src/network/`
imports it for `Url`, `HttpResponse`, cookie/cache/policy aliases and helpers,
and the `Url.fetchBody*` family. Those fetch methods remain the
browser-independent public boundary; they delegate rather than implementing
HTTP inline.

The implementation behind that facade is split by ownership:

- `response.zig` defines response metadata and stateless response-policy,
  CORS, and UTF-8 decoding helpers;
- `cookie.zig` defines owning cookie entries and the parser/selection
  operations over a caller-owned jar;
- `cache.zig` owns cache entries and keys, freshness, Cache-Control, and the
  scalar response-policy types retained by cached responses;
- `transport.zig` borrows the caller's client, jar, cache, URLs, and optional
  network mutex while it performs scheme dispatch, HTTP, redirects, and
  cookie/cache coordination.

The facade imports and re-exports the leaf types and delegates to transport.
Transport imports the response, cookie, and cache leaves, but receives `Url`
and the URL-specific fragment/referrer operations as comptime parameters; it
does not import the facade back and therefore does not create a cycle.
`transport.fetchBodyInternal` is an internal seam. Preserve the facade when
adding a fetch mode so inspection, Browser, and tests retain one ownership
contract.

## URL ownership

`url.zig` owns URL identity and scheme-local parsing/storage, not the
browser-session HTTP client, cookie jar, or cache. `Url` wraps an owning Ada URL
and may also own decoded data-URL storage. Ordinary Zig assignment is a shallow
copy, so treat it as logically move-only:

- borrow it only for a synchronous call whose owner remains alive;
- use `Url.clone` for two independently live owners;
- use `Url.toOwnedString` for a key or snapshot that must outlive it;
- call `free` exactly once on each owner.

Component and fragment slices borrow Ada storage. `sameDocument` ignores only
the fragment; query remains part of identity. HTTP requests and cache keys omit
fragments, while a requested fragment is restored after a redirect/cache hit
unless the destination supplied one.

Document-replacing targets use `initForNavigation` and
`resolveForNavigation`: allocation errors remain errors, while malformed or
unsupported navigation becomes an independently owned `about:blank`.
Subresources use strict `init`/`resolve` so one bad resource cannot replace the
containing page.

## Response ownership

`response.zig` defines `Response`, re-exported by the facade as `HttpResponse`.
The value has no deinitializer and its slice types do not encode ownership.
Current behavior is:

- HTTP and file bodies are allocated by the caller-provided allocator;
- data bodies borrow decoded storage owned by the request `Url`, and about
  bodies borrow static storage;
- HTTP and cache hits return an independently owned `csp_header` when present;
- only an Origin-bearing HTTP request can return an independently owned
  `access_control_allow_origin`;
- status, Cache-Control, Referrer-Policy, and X-Frame-Options are scalars.

Preserve the boundary and release via the known request owner; do not infer
ownership at an unrelated distant call site. A tagged response owner remains a
desired cleanup.

`NavigationDocument` makes document-fetch ownership explicit: allocated
HTTP/file data, generated bookmark HTML, and certificate-warning HTML use its
owned-body field; data/about bodies leave that field absent. Keep the wrapper
alive until the Frame has copied/decoded the document.

## Cache ownership

`cache.HttpCache` owns its allocator, canonical fragment-free URL keys, decoded
bodies, optional CSP headers, optional final redirect URLs, freshness
deadlines, and retained scalar policies. `store` duplicates the supplied
slices. `lookup` returns borrowed entry storage which is valid only until the
next mutation or cache deinitialization; it does not itself produce a public
fetch result.

Transport performs lookup under the session network mutex and duplicates a
hit's body, CSP header, and final URL before unlocking. The resulting
`HttpResponse` therefore obeys the same caller ownership contract as an HTTP
round trip and reproduces Referrer-Policy and X-Frame-Options. Ordinary
cacheable GET responses use the cache; POST and Origin-bearing CORS requests
bypass it.

## Session network boundary

Interactive cookies, cache, HTTP client, and request runner belong to the
shared `BrowserSession`. Standalone screenshot Browser owns its own session.
Each heap-stable Browser embeds a `resource_loader.Loader` that borrows this
session. Ordinary requests synchronously bridge through the networking runner;
their stack task contexts borrow the Loader and request inputs only until the
runner cleanup posts the completion semaphore. The Loader owns no independent
thread or transport state and therefore has no separate shutdown phase. The
inspection CLI intentionally calls the browser-independent `Url.fetchBody*`
facade directly; it does not import `transport.zig`.

Transport owns only per-call temporaries and returned allocations. It borrows
the supplied request URL, referrer, payload, Origin, HTTP client, cookie jar,
cache, and optional mutex for the synchronous call. Cookie and cache updates
are mutations of `BrowserSession` state, not state retained by the transport
module.

The network-data mutex covers only shared map lookup, copying, eviction, and
mutation. Copy Cookie headers and cached responses before unlocking, then leave
the lock released for the round trip so independent requests can overlap.

A linked-resource batch crosses the networking queue as one task. Build the
complete slot array first; each slot owns its resolved URL and referrer. The
network task starts and joins transport workers, then the Tab consumes slots in
DOM source order. Completion order must not reorder classic scripts or CSS
cascade order. Batch transport workers borrow the Loader and their slot, call
the synchronized low-level transport directly, and are all joined before the
batch can be consumed or destroyed.

## Root document replacement

A successful root navigation transaction follows this order:

1. keep the old Frame URL/document alive while deriving Referer policy and
   fetching/decoding the candidate; failure leaves the old page installed;
2. determine the final redirect URL and prepare all history URL/body/path/tree
   owners and collection capacity;
3. invalidate old document generations, JavaScript roots, and host callbacks;
4. reject/clean queued old-generation work and quiesce relevant helpers;
5. retire Browser render state under `Browser.lock`;
6. destroy old frame display/layout before DOM, DOM before CSS/HTML source
   chunks and buffers,
   and the owning URL last;
7. allocate/register the new Frame and stage its URL, decoded HTML, response
   policy, and source store before publishing any script-visible document
   state;
8. assign a fresh document generation, publish the final-address root and its
   Realm, then drive the live parser. Each parser-inserted classic script runs
   synchronously in source order; `document.write` chunks are copied into the
   Frame source store ahead of unread input. Fetch/evaluation failures are
   page errors and parsing continues;
9. after EOF, discover deferred resources, build stylesheet/rule generations,
   and build style/layout/paint;
10. apply a final fragment after layout and clamp scroll;
11. append the already prepared history action only after the replacement and
    any nested restoration succeeds.

Before reclaiming old state, no new task may target its generation, no JS or
input path may expose old pointers, Browser snapshots must be retired,
invalidation dependencies must be detached, and every owning URL/body must
still have exactly one release path.

## Child-frame replacement

Child navigation reuses the heap-stable Frame allocation but resets its
document generation. Fetch the candidate while the old referrer and policy are
valid; only then clear JS roots/callbacks and retire display, children, layout,
DOM, rules/keyframes, stylesheet text, decoded HTML, and URL in dependency
order. Stage the new URL/source before publishing the final root, then use the
same synchronous live-parser script ordering as a root navigation.

Parent CSP checks both requested and final redirect destinations. After final
response identity is known, apply X-Frame-Options before recording a visit,
history action, or child document:

- `DENY` rejects every embedding chain;
- `SAMEORIGIN` requires the final response to match every live ancestor origin
  and fails closed when an ancestor URL is unavailable;
- unknown values and obsolete `ALLOW-FROM` are ignored by this implementation;
- top-level navigation does not consult this embedding-only policy.

Script-added iframes load only during the deferred resource refresh after the
host mutation returns. The synchronous completion boundary rebinds surviving
numeric Element markers and destroys removed child contexts before JavaScript
resumes.

## Joint history

One Tab owns an indexed history for root and iframe actions. Each action owns:

- the resulting URL, method, and optional POST body;
- a child-index path from the root, never a `*Frame`;
- whether it replaces a document;
- an owned recursive snapshot of the target subtree immediately before the
  navigation.

Prepare every clone and list capacity before retiring a live document.
Ordinary navigation truncates the Forward branch before appending. Back
restores the current action's prior subtree; Forward reapplies the next action.
Move the shared index only after the complete operation succeeds. This keeps
interleaved sibling-frame history independent and lets a restored parent
recreate its former nested state.

History UI reads atomic availability flags and schedules work; the Tab worker
revalidates the adjacent action and generation. A traversal that would replay
POST asks on the UI thread without holding `Browser.lock`. Cancel schedules
nothing. Resubmit queues a generation-checked worker task. Same-document
fragment actions do not resend retained POST metadata.

## Stylesheet and dynamic-resource generations

A Frame's stylesheet texts, parsed rules, and named keyframes are one owner
generation. Rules and declaration slices borrow those texts. Stage and validate
the complete replacement before retiring the old generation.

Media-environment changes rebuild all retained author sheets on the serialized
render path, then dirty computed style. Root media width/height are native
content-viewport dimensions divided by accessibility zoom. Iframe media
dimensions divide authored-zoom-scaled published geometry by the inherited
authored factor. Changes to either axis or that inherited factor dirty child
layout and schedule the follow-up media/style pass; a height-only resize must
not reuse rules selected for the old height.

Structural DOM mutation marks attached resources dirty. The next worker pass
queues each newly attached classic script once and rebuilds the complete live
stylesheet generation in DOM order. Removing a script never rolls evaluated
code back; reattaching the same `script_started` Element does not evaluate it
again. Scripts parsed as an `innerHTML` fragment are intentionally inert, even
when the source came from serializing a previously executed script; only an
explicitly created-and-attached script remains eligible for this deferred path.
Removing a link retires its stylesheet rules.

## Images and background images

HTML images are discovered eagerly unless `loading=lazy` matches
case-insensitively. Layout publishes copied image bounds; before each animation
dirty gate, the Tab selects lazy images within one CSS-pixel viewport above or
below the visible area. A decoded image or stable broken fallback always dirties
layout and paint because natural dimensions may change flow. Terminal state is
stored on the Element to avoid repeated requests. Broken fallback pixels paint
only when `alt` is non-empty.

CSS background resources are discovered only after final cascade. Do not fetch
an overridden, unmatched, `display:none`, hidden-input, unsupported, or
forced-colors-suppressed image. The Element owns attempted-source identity and
optional decoded pixels. Before replacing pixels, retire frame and Browser
display borrowers. Resolve against the document and apply its CSP and referrer
policy.

## Referrer policy

Every Frame stores the Referrer-Policy of its current response generation.
Navigation, images, iframes, scripts, styles, backgrounds, and XHR pass that
policy plus the source URL:

- Referer omits the fragment;
- `no-referrer` always suppresses it;
- `same-origin` suppresses it when scheme, host, or effective port differs.

Policy suppression does not erase the initiator from the synchronous request
context because SameSite cookie selection still needs it. Async XHR clones the
source URL and copies policy before leaving its document generation.

## CORS and CSP

Cross-origin XHR is fetched rather than rejected before transport. It sends an
owned canonical `Origin` and target-host cookies, bypasses the ordinary
response cache, and exposes the response only when
`Access-Control-Allow-Origin` is the exact requester origin or `*`. A denied
synchronous request reports `CrossOriginBlocked`; an asynchronous denial frees
the response and schedules no `onload` because this browser subset has no
XHR `onerror` event. Same-origin XHR needs neither Origin nor response opt-in.

CSP remains a request-side gate and may reject before transport. It applies to
both requested and final iframe destinations and to all supported subresources.

## Cookies

The `BrowserSession` tutorial jar owns one entry per normalized host. The jar
owns each host key; its `cookie.Entry` owns the value and optional raw parameter
string alongside derived SameSite/HttpOnly state and optional absolute
expiration. `cookie.zig` supplies operations over that jar but owns no global
jar. HTTP Set-Cookie and script assignment use one transactional parser.

- Replacing a cookie replaces its deadline.
- An already-expired assignment deletes the existing entry.
- HTTP and script reads lazily remove expired owning entries under the network
  mutex.
- HttpOnly cookies remain request-visible but script-hidden and
  script-immutable; script cannot create HttpOnly state.
- `cookieForScript` returns an independent allocation. The leaf
  `cookieForRequest` returns a borrowed entry value; transport duplicates it
  while holding the network mutex before adding it to a request.
- `document.cookie` copies results before unlocking and then moves bytes into
  Kiesel's traced allocator because string construction may retain them.

## Navigation UI and visited state

Address-bar interpretation belongs to Chrome: explicit schemes and obvious
bare hosts navigate directly, while other input becomes a form-encoded search.
Document links stay strict and never silently become searches.

Every successful root/child navigation, fragment navigation, and queued
middle-click target records canonical visited state; redirects record requested
and final destinations. DOM anchors retain only a boolean annotation. Session
generations cause each live Browser to request a repaint without exposing URL
map storage.

Certificate-verification failures become owned warning documents with no
bypass and are not recorded as successful visits. Chrome draws a lock only
when its displayed URL exactly matches a committed, verified HTTPS document;
optimistic text and warning pages must not inherit stale security UI.

## Known type gaps

- `Url` is move-only by convention, not by the Zig type system.
- Response body ownership is inferred from scheme rather than encoded in a
  tagged owner.
- Async HTTP is accounted but not cancellable.

Tests for ownership changes should prefer data/file URLs and reclaiming
allocators. Use a local deterministic server for redirects, cookies,
compression, caching, CORS, CSP, X-Frame-Options, or concurrency.
