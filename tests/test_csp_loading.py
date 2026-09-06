"""Deterministic HTTP CSP regressions against a real headless Zibra executable.

Run: python3 tests/test_csp_loading.py ./zig-out/bin/zibra
The server binds only loopback; every browser has a process-group watchdog.
"""

from http.server import BaseHTTPRequestHandler, HTTPServer
import json
from pathlib import Path
import sys
import struct
import threading
import unittest
import zlib

from wpt.run import _invoke


BROWSER = str(Path(sys.argv.pop(1)).resolve()) if len(sys.argv) > 1 else "./zig-out/bin/zibra"
def png_chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


PIXEL = (b"\x89PNG\r\n\x1a\n"
         + png_chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
         + png_chunk(b"IDAT", zlib.compress(b"\x00\x00\x80\x00\xff"))
         + png_chunk(b"IEND", b""))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.server.requests.append(self.path)
        port = self.server.server_port
        assets = f"http://localhost:{port}"
        origin = f"http://127.0.0.1:{port}"
        policies = []
        content_type = "text/html"
        if self.path == "/routing":
            policies = [
                "default-src 'none'; "
                f"style-src localhost:{port}; script-src localhost:{port}; "
                f"img-src localhost:{port}; connect-src 'self'; frame-src localhost:{port}"
            ]
            body = f"""<!doctype html><link rel=stylesheet href="{assets}/allowed.css">
                <link rel=stylesheet href="{origin}/forbidden.css">
                <div id=measured>Allowed stylesheet</div><div id=background></div>
                <img src="{assets}/allowed.png"><img src="{origin}/forbidden.png">
                <iframe src="{assets}/allowed-frame"></iframe>
                <iframe src="{origin}/forbidden-frame"></iframe>
                <script src="{origin}/forbidden.js"></script>
                <script src="{assets}/allowed.js"></script>"""
        elif self.path == "/allowed.css":
            content_type = "text/css"
            body = f"""#measured {{ width:173px; height:29px; background:green }}
                #background {{ width:20px; height:20px; background-image:url('{assets}/background.png') }}"""
        elif self.path == "/allowed.js":
            content_type = "text/javascript"
            body = f"""
                var results = [];
                function check(name, value) {{ results.push({{name:name, status:value ? 0 : 1}}); }}
                check('external stylesheet applied', document.getElementById('measured').offsetWidth === 173);
                check('forbidden same-origin script did not execute', typeof forbiddenScript === 'undefined');
                var xhr = new XMLHttpRequest();
                xhr.open('GET', '/allowed-xhr', false); xhr.send();
                check('connect-src self allows XHR', xhr.responseText === 'ok');
                var blocked = false;
                try {{
                    var denied = new XMLHttpRequest();
                    denied.open('GET', '{assets}/forbidden-xhr', false); denied.send();
                }} catch (error) {{ blocked = true; }}
                check('connect-src rejects cross-origin XHR before transport', blocked);
                setTimeout(function() {{ completion_callback(results, {{status:0}}); }}, 0);
            """
        elif self.path == "/intersection":
            # A last-header-wins transport or unconditional same-origin bypass
            # fetches forbidden.css. Both response policies must be enforced.
            policies = ["style-src 'none'", "style-src *"]
            body = f"""<!doctype html><link rel=stylesheet href="{origin}/forbidden.css">
                <script>setTimeout(function() {{ completion_callback([
                {{name:'response policy list loaded', status:0}}], {{status:0}}); }}, 0);</script>"""
        elif self.path in ("/allowed.png", "/background.png", "/forbidden.png"):
            content_type = "image/png"
            body = PIXEL
        elif self.path == "/allowed-xhr":
            content_type = "text/plain"
            body = "ok"
        elif self.path == "/forbidden.css":
            content_type = "text/css"
            body = "#measured { width:999px; background:red }"
        elif self.path == "/forbidden.js":
            content_type = "text/javascript"
            body = "var forbiddenScript = true;"
        elif self.path in ("/allowed-frame", "/forbidden-frame"):
            body = "<!doctype html><p>Child frame</p>"
        else:
            content_type = "text/plain"
            body = "forbidden request reached server"
        if isinstance(body, str):
            body = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        for policy in policies:
            self.send_header("Content-Security-Policy", policy)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class CspLoadingTests(unittest.TestCase):
    def setUp(self):
        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        self.server.requests = []
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05})
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.thread.join()
        self.server.server_close()

    def load(self, path):
        url = f"http://127.0.0.1:{self.server.server_port}{path}"
        result = _invoke([BROWSER, "--wpt-test", url, "--wpt-timeout-ms", "5000"], 10)
        self.assertIsNone(result.infrastructure_error, result.stderr)
        record = json.loads(result.stdout)
        self.assertEqual(record["status"], "PASS", result.stdout + result.stderr)

    def test_destination_specific_sources_reach_cascade_and_transport(self):
        self.load("/routing")
        self.assertEqual(set(self.server.requests), {
            "/routing", "/allowed.css", "/allowed.js", "/allowed.png",
            "/background.png", "/allowed-xhr", "/allowed-frame",
        })

    def test_repeated_headers_intersect_and_forbid_same_origin_styles(self):
        self.load("/intersection")
        self.assertEqual(self.server.requests, ["/intersection"])


if __name__ == "__main__":
    unittest.main()
