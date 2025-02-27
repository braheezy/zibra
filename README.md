# zibra

This repo holds my Zig code for the browser implemented in [Web Browser Engineering](https://browser.engineering/).

## Usage

You'll need Zig installed.

Clone the project

```sh
git clone https://github.com/braheezy/zibra.git
```

To build the project, run:

```sh
zig build
cp zig-out/bin/zibra .
```

`zibra` (optionally) takes one URL and displays the result in a window:

```sh
> zibra https://example.org
```

Run without a URL for a default HTML.

## Supported Features

`zibra` is small but supports the basics:

- HTTP/1.1
- HTTPS
- `file://` URIs
- `data:` URIs
- Entity support:
  - `&amp;` → `&` (ampersand)
  - `&lt;` → `<` (less than)
  - `&gt;` → `>` (greater than)
  - `&quot;` → `"` (quotation mark)
  - `&apos;` → `'` (apostrophe)
  - `&shy;` → `­` (soft hyphen)
- Connections that live beyond single request for `Connection: keep-alive` header
- Redirects
- `Cache-Control` header
- `Content-Encoding: gzip` and `Transfer-Encoding: chunked` headers
- Emojis and CJK text
- Various tags for styling:
  - `<b>Bold</b>`
  - `<i>Italic</i>`
  - `<big>Larger text</big>`
  - `<small>Smaller text</small>`
  - `<sup>Superscript</sup>`
  - `<h1 class="title">Centered title</h1>`: An `h1` with `class` set to `title` will be centered
  - `<abbr>Abbreviations</abbr>`

## Development

There's more Zig commands:

```sh
# build and run
zig build run -- https://example.com
# Run rests
zig build test
```

To test chunked gzip responses, run `gzipServer.py` locally.

## Known Issues

- On Mac, the content is stretched while the window is being resized. Apparently this is known behavior in SDL2 because Mac blocks the main thread while the mouse is being held down to resize windows, preventing SDL from rendering the content properly...I think.

---
