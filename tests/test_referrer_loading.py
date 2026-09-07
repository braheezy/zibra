"""Wire-level Referrer Policy regressions; loopback server and reaped browsers.

Run: python3 tests/test_referrer_loading.py ./zig-out/bin/zibra
"""
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
from pathlib import Path
import sys
import threading
import unittest
from urllib.parse import urlsplit, parse_qs

from wpt.run import _invoke

BROWSER = str(Path(sys.argv.pop(1)).resolve()) if len(sys.argv) > 1 else "./zig-out/bin/zibra"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.server.requests.append((self.path, self.headers.get("Referer")))
        self.server.cookies.append((self.path, self.headers.get("Cookie")))
        path = urlsplit(self.path).path
        origin = f"http://127.0.0.1:{self.server.server_port}"
        cross = f"http://localhost:{self.server.server_port}"
        status, headers, mime = 200, [], "text/html"
        if path == "/page":
            headers = [("Referrer-Policy", "unsafe-url, origin, unknown"),
                       ("Referrer-Policy", "invalid"),
                       ("Set-Cookie", "page=present; SameSite=Lax")]
            body = f"""<!doctype html>
                <script src='/before.js'></script>
                <meta name=referrer content=no-referrer>
                <script src='/none.js'></script>
                <script src='{cross}/override.js' referrerpolicy=unsafe-url></script>
                <link rel=stylesheet href='/sheet-redirect' referrerpolicy=origin>
                <img src='{cross}/image.ppm' referrerpolicy=origin>
                <iframe src='{cross}/child' referrerpolicy=unsafe-url></iframe>
                <div id=background></div>
                <div style="width:10px;height:10px;background-image:url(inline.ppm)"></div>
                <script>
                var results = [];
                function check(name, value) {{ results.push({{name:name,status:value?0:1}}); }}
                function echo() {{ var x=new XMLHttpRequest(); x.open('GET','/echo',false); x.send(); return x.responseText; }}
                check('initial document has no incoming referrer', document.referrer === '');
                check('meta suppresses XHR', echo() === '');
                var first=document.createElement('meta'); first.name='referrer'; first.content='origin';
                document.head.appendChild(first);
                check('dynamic meta content reflected', echo() === '{origin}/');
                var second=document.createElement('meta'); second.name='referrer'; second.content='unsafe-url';
                document.head.insertBefore(second, first);
                check('insertion order beats tree order', echo() === '{origin}/page?private=1');
                first.content='no-referrer'; first.remove(); second.remove();
                check('modification persists after removal', echo() === '');
                new DOMParser().parseFromString('<meta name=referrer content=unsafe-url>', 'text/html');
                check('detached parsing is inert', echo() === '');
                var x=new XMLHttpRequest(); x.open('GET','{cross}/redirect-none',false); x.send();
                check('redirect cannot restore suppressed referrer', x.responseText === '');
                first.content='unsafe-url'; document.head.appendChild(first);
                x=new XMLHttpRequest(); x.open('POST','/post-redirect',false); x.send('payload');
                check('307 preserves POST body and applies policy', x.responseText === 'payload|{origin}/');
                x=new XMLHttpRequest(); x.open('POST','/post-to-get',false); x.send('payload');
                check('303 switches to GET and suppresses referrer', x.responseText === '');
                first.content='no-referrer'; first.remove();
                setTimeout(function() {{ completion_callback(results,{{status:0}}); }},0);
                </script>"""
        elif path in ("/before.js", "/none.js", "/override.js"):
            mime, body = "text/javascript", "/* request policy probe */"
        elif path == "/sheet-redirect":
            status, body = 302, ""
            headers = [("Location", cross + "/assets/site.css"), ("Referrer-Policy", "no-referrer")]
        elif path == "/assets/site.css":
            mime = "text/css"
            headers = [("Referrer-Policy", "unsafe-url")]
            body = "#background {width:20px;height:20px;background-image:url(background.ppm)}"
        elif path.endswith(".ppm"):
            mime, body = "image/x-portable-pixmap", "P3\n1 1\n255\n0 128 0\n"
        elif path == "/child":
            headers = [("Referrer-Policy", "no-referrer")]
            body = """<script>var x=new XMLHttpRequest();
                x.open('GET','/child-seen?value='+encodeURIComponent(document.referrer),false);x.send();</script>"""
        elif path == "/redirect-none":
            status, body = 302, ""
            headers = [("Location", "/redirect-unsafe"), ("Referrer-Policy", "no-referrer")]
        elif path == "/redirect-unsafe":
            status, body = 302, ""
            headers = [("Location", "/echo"), ("Referrer-Policy", "unsafe-url")]
        else:
            mime, body = "text/plain", self.headers.get("Referer", "")
        body = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self.server.requests.append((self.path, self.headers.get("Referer")))
        self.server.cookies.append((self.path, self.headers.get("Cookie")))
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.path == "/post-final":
            body += b"|" + self.headers.get("Referer", "").encode()
            self.send_response(200)
        else:
            self.send_response(303 if self.path == "/post-to-get" else 307)
            self.send_header("Location", "/echo" if self.path == "/post-to-get" else "/post-final")
            self.send_header("Referrer-Policy", "no-referrer" if self.path == "/post-to-get" else "origin")
            body = b""
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class ReferrerLoadingTests(unittest.TestCase):
    def setUp(self):
        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        self.server.requests = []
        self.server.cookies = []
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05})
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.thread.join()
        self.server.server_close()

    def test_headers_meta_overrides_redirects_css_and_document_referrer(self):
        origin = f"http://127.0.0.1:{self.server.server_port}"
        cross = f"http://localhost:{self.server.server_port}"
        result = _invoke([BROWSER, "--wpt-test", origin + "/page?private=1#hidden", "--wpt-timeout-ms", "10000"], 20)
        self.assertIsNone(result.infrastructure_error, result.stderr)
        record = json.loads(result.stdout)
        self.assertEqual(record["status"], "PASS", result.stdout + result.stderr)
        requests = dict(self.server.requests)
        self.assertEqual(requests["/before.js"], origin + "/")
        self.assertIsNone(requests["/none.js"])
        # Suppressing Referer must not suppress the independent cookie context.
        self.assertEqual(dict(self.server.cookies)["/none.js"], "page=present")
        self.assertEqual(requests["/override.js"], origin + "/page?private=1")
        self.assertEqual(requests["/sheet-redirect"], origin + "/")
        self.assertIsNone(requests["/assets/site.css"])
        self.assertEqual(requests["/assets/background.ppm"], cross + "/assets/site.css")
        self.assertIsNone(dict(self.server.cookies)["/assets/background.ppm"])
        self.assertIsNone(requests["/inline.ppm"])
        self.assertEqual(requests["/image.ppm"], origin + "/")
        self.assertEqual(requests["/child"], origin + "/page?private=1")
        child = [(p, r) for p, r in self.server.requests if p.startswith("/child-seen?")]
        self.assertEqual(len(child), 1)
        self.assertEqual(parse_qs(urlsplit(child[0][0]).query)["value"], [origin + "/page?private=1"])
        self.assertIsNone(child[0][1])


if __name__ == "__main__":
    unittest.main()
