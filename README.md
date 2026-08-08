# zibra

> [!WARNING]
> This project is actively in work! `HEAD` usually works but it may be broken or produce nasty results.

This repo holds my Zig code for the browser implemented in [Web Browser Engineering](https://browser.engineering/).

Where possible, this project takes the most difficult route possible to implement features that are implemented quite easily in the book. It benefits from Python and mature third-party libraries and bindings. We get no such benefits.

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
zibra https://example.org
```

Run without a URL for a default HTML.

## Development

There's more Zig commands:

```sh
# build and run
zig build run -- https://example.com
# Inspect a document without starting SDL, layout, JavaScript, or rendering
zig build run -- --dump-dom https://example.com
# Run tests
zig build test
# Capture and compare the native macOS screenshot fixture
zig build test-screenshot
```

To test chunked gzip responses, run `gzipServer.py` locally.

See [Architecture and lifetimes](docs/architecture-and-lifetimes.md) for the source map, ownership contracts, threading model, and known lifetime risks.

## Known Issues

- On Mac, the content is stretched while the window is being resized. Apparently this is known behavior in SDL2 because Mac blocks the main thread while the mouse is being held down to resize windows, preventing SDL from rendering the content properly...I think.
