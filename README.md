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

`zibra` takes one or more URLs and displays the result in raw text on the command line.

```sh
> zibra https://example.org

Connecting to example.org:443
HTTP/1.1 200 OK

    Example Domain

    body {
        background-color: #f0f0f2;
        margin: 0;
        padding: 0;
        font-family: -apple-system, system-ui, BlinkMacSystemFont, "Segoe UI", "Open Sans", "Helvetica Neue", Helvetica, Arial, sans-serif;

    }
    div {
        width: 600px;
    ...

    Example Domain
    This domain is for use in illustrative examples in documents. You may use this
    domain in literature without prior coordination or asking for permission.
    More information...
```

## Supported Features

`zibra` is small but supports the basics:

- HTTP/1.1
- HTTPS
- `file://` URIs
- `data:` URIs
- Entity support (`&lt;div&gt` becomes `<div>`)
- `view-source:`
- Connections that live beyond single request for `Connection: keep-alive` header
- Redirects
- `Cache-Control` header
- `Content-Encoding: gzip` and `Transfer-Encoding: chunked` headers

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
