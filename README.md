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
        margin: 5em auto;
        padding: 2em;
        background-color: #fdfdff;
        border-radius: 0.5em;
        box-shadow: 2px 3px 7px 2px rgba(0,0,0,0.02);
    }
    a:link, a:visited {
        color: #38488f;
        text-decoration: none;
    }
    @media (max-width: 700px) {
        div {
            margin: 0 auto;
            width: auto;
        }
    }





    Example Domain
    This domain is for use in illustrative examples in documents. You may use this
    domain in literature without prior coordination or asking for permission.
    More information...


```

## Development

There's more Zig commands:

```sh
# build and run
zig build run -- https://example.com
# Run rests
zig build test
```

To test chunked gzip responses, run `gzipServer.py` locally.
