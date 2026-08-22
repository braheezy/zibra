#!/usr/bin/env python3
"""Serve the threaded-loading fixture with equal per-resource latency."""

from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import time


DELAYED_RESOURCES = {
    "/threaded-loading-a.css",
    "/threaded-loading-b.css",
    "/threaded-loading-a.js",
    "/threaded-loading-b.js",
}


class DelayedHandler(SimpleHTTPRequestHandler):
    def do_GET(self):
        path = self.path.partition("?")[0]
        if path in DELAYED_RESOURCES:
            time.sleep(0.75)
        super().do_GET()


if __name__ == "__main__":
    fixture_dir = Path(__file__).resolve().parent
    handler = partial(DelayedHandler, directory=str(fixture_dir))
    server = ThreadingHTTPServer(("127.0.0.1", 8000), handler)
    print("Serving delayed resources at http://127.0.0.1:8000/threaded-loading.html")
    server.serve_forever()
