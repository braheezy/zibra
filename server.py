#!/usr/bin/env python3
"""
Simple web server for testing form submissions.
Based on the Web Browser Engineering book.
"""

import socket
import urllib.parse

# Guest book entries storage
ENTRIES = ['braheezy was here']

def handle_connection(conx):
    """Handle a single HTTP connection."""
    req = conx.makefile("b")
    reqline = req.readline().decode('utf8')
    method, url, version = reqline.split(" ", 2)
    assert method in ["GET", "POST"]

    # Read headers
    headers = {}
    while True:
        line = req.readline().decode('utf8')
        if line == '\r\n':
            break
        header, value = line.split(":", 1)
        headers[header.casefold()] = value.strip()

    # Read body if present
    if 'content-length' in headers:
        length = int(headers['content-length'])
        body = req.read(length).decode('utf8')
    else:
        body = None

    # Process the request
    status, response_body = do_request(method, url, headers, body)

    # Send response
    response = "HTTP/1.0 {}\r\n".format(status)
    response += "Content-Length: {}\r\n".format(
        len(response_body.encode("utf8")))
    response += "\r\n" + response_body
    conx.send(response.encode('utf8'))
    conx.close()

def do_request(method, url, headers, body):
    """Process the HTTP request and return status and body."""
    if method == "GET" and url == "/":
        return "200 OK", show_comments()
    elif method == "POST" and url == "/add":
        params = form_decode(body)
        return "200 OK", add_entry(params)
    else:
        return "404 Not Found", not_found(url, method)

def show_comments():
    """Generate HTML page showing all guest book entries."""
    out = "<!doctype html>"
    for entry in ENTRIES:
        out += "<p>" + entry + "</p>"
    out += "<form action=add method=post>"
    out +=   "<p><input name=guest></p>"
    out +=   "<p><button>Sign the book!</button></p>"
    out += "</form>"
    return out

def form_decode(body):
    """Decode form data from the request body."""
    params = {}
    for field in body.split("&"):
        name, value = field.split("=", 1)
        name = urllib.parse.unquote_plus(name)
        value = urllib.parse.unquote_plus(value)
        params[name] = value
    return params

def add_entry(params):
    """Add a new entry to the guest book."""
    if 'guest' in params:
        ENTRIES.append(params['guest'])
    return show_comments()

def not_found(url, method):
    """Generate a 404 page."""
    out = "<!doctype html>"
    out += "<h1>{} {} not found!</h1>".format(method, url)
    return out

def main():
    """Start the web server."""
    s = socket.socket(
        family=socket.AF_INET,
        type=socket.SOCK_STREAM,
        proto=socket.IPPROTO_TCP)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)

    s.bind(('', 8000))
    s.listen()

    print("Server listening on http://localhost:8000")
    print("Press Ctrl+C to stop")

    try:
        while True:
            conx, addr = s.accept()
            print(f"Connection from {addr}")
            handle_connection(conx)
    except KeyboardInterrupt:
        print("\nShutting down server...")
        s.close()

if __name__ == "__main__":
    main()
