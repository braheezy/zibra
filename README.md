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

Development commands:

```sh
# build and run
zig build run -- https://example.com
# Inspect individual document-pipeline stages without an interactive browser
zig build run -- --dump-dom https://example.com
zig build run -- --dump-style https://example.com
zig build run -- --dump-layout https://example.com
zig build run -- --dump-display-list https://example.com
# Run tests
zig build test
# Run a focused subsystem while iterating
zig build test-document
zig build test-render
zig build test-network
zig build test-script
zig build test-browser
# Compare deterministic style, layout, and display-list output
zig build test-pipeline
# Run every portable build, test, formatting, pipeline, server, and docs check
zig build check
# Capture and compare the windowless macOS screenshot fixtures
zig build test-screenshot
```

See [Testing and verification](docs/testing.md) for the focused-test map,
golden policy, native visual checks, and manual-fixture catalog.

To test chunked gzip responses, run `gzipServer.py` locally.

The tutorial server is now a small topic-based message board. Start it with:

```sh
python3 server.py
```

Then open `http://127.0.0.1:8005/`. Sign in with one of the tutorial accounts
(for example `a` / `b`) to create topics and post messages. Each topic has its
own root-level URL, such as `/cooking` or `/cars`. The server atomically saves
the whole board to `message_board.json`, so topics and messages survive a
restart. Set `ZIBRA_BOARD_DATA` to use a different data-file path:

```sh
ZIBRA_BOARD_DATA=/path/to/my-board.json python3 server.py
```

See [Architecture and lifetimes](docs/architecture-and-lifetimes.md) for the source map, ownership contracts, threading model, and known lifetime risks.

## Known Issues

- On Mac, the content is stretched while the window is being resized. Apparently this is known behavior in SDL2 because Mac blocks the main thread while the mouse is being held down to resize windows, preventing SDL from rendering the content properly...I think.
