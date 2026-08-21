import email.utils
import html
import json
import os
from pathlib import Path
import random
import re
import socket
import tempfile
import time
import unicodedata
import urllib.parse


SESSIONS = {}
SESSION_LIFETIME_SECONDS = 30 * 24 * 60 * 60

LOGINS = {
    "crashoverride": "0cool",
    "cerealkiller": "emmanuel",
    "a": "b",
}

RESERVED_TOPIC_SLUGS = {
    "add",
    "comment-js",
    "comment-css",
    "count",
    "eventloop-js",
    "login",
    "new-topic",
    "referer",
    "referrer-policy",
    "xhr",
    "xhr-denied",
}

DATA_VERSION = 1
DATA_PATH = Path(
    os.environ.get("ZIBRA_BOARD_DATA", Path(__file__).with_name("message_board.json"))
)


def slugify_topic(title):
    normalized = unicodedata.normalize("NFKD", title)
    ascii_title = normalized.encode("ascii", "ignore").decode("ascii").casefold()
    slug = "-".join(re.findall(r"[a-z0-9]+", ascii_title))
    return slug[:48].strip("-")


def default_topics():
    """Return a fresh copy of the board shipped with the tutorial server."""
    return {
        "general": {
            "title": "General",
            "description": "Introductions, announcements, and everything in between.",
            "created_by": "system",
            "messages": [
                ("No names. We are nameless!", "cerealkiller"),
                ("HACK THE PLANET!!!", "crashoverride"),
            ],
        },
        "cooking": {
            "title": "Cooking",
            "description": "Recipes, techniques, and strong opinions about cast iron.",
            "created_by": "system",
            "messages": [("What is your favorite weeknight meal?", "cerealkiller")],
        },
        "cars": {
            "title": "Cars",
            "description": "Repairs, road trips, and machines with personality.",
            "created_by": "system",
            "messages": [
                ("Manual transmissions still count as user interfaces.", "crashoverride")
            ],
        },
    }


def topics_to_json(topics):
    return {
        "version": DATA_VERSION,
        "topics": {
            slug: {
                "title": topic["title"],
                "description": topic["description"],
                "created_by": topic["created_by"],
                "messages": [
                    {"text": message, "author": author}
                    for message, author in topic["messages"]
                ],
            }
            for slug, topic in topics.items()
        },
    }


def topics_from_json(data):
    if not isinstance(data, dict) or data.get("version") != DATA_VERSION:
        raise ValueError("unsupported message-board data version")
    raw_topics = data.get("topics")
    if not isinstance(raw_topics, dict):
        raise ValueError("message-board topics must be an object")

    topics = {}
    for slug, raw_topic in raw_topics.items():
        if (
            not isinstance(slug, str)
            or not slug
            or slugify_topic(slug) != slug
            or slug in RESERVED_TOPIC_SLUGS
        ):
            raise ValueError("message-board data contains an invalid topic slug")
        if not isinstance(raw_topic, dict):
            raise ValueError("message-board topic must be an object")

        title = raw_topic.get("title")
        description = raw_topic.get("description")
        created_by = raw_topic.get("created_by")
        raw_messages = raw_topic.get("messages")
        if not isinstance(title, str) or not title.strip() or len(title) > 60:
            raise ValueError("message-board topic has an invalid title")
        if not isinstance(description, str) or len(description) > 120:
            raise ValueError("message-board topic has an invalid description")
        if not isinstance(created_by, str) or not created_by:
            raise ValueError("message-board topic has an invalid creator")
        if not isinstance(raw_messages, list):
            raise ValueError("message-board messages must be an array")

        messages = []
        for raw_message in raw_messages:
            if not isinstance(raw_message, dict):
                raise ValueError("message-board message must be an object")
            message = raw_message.get("text")
            author = raw_message.get("author")
            if (
                not isinstance(message, str)
                or not message.strip()
                or len(message) > 280
            ):
                raise ValueError("message-board entry has invalid text")
            if not isinstance(author, str) or not author:
                raise ValueError("message-board entry has an invalid author")
            messages.append((message, author))

        topics[slug] = {
            "title": title,
            "description": description,
            "created_by": created_by,
            "messages": messages,
        }

    if "general" not in topics:
        raise ValueError("message-board data must contain the General topic")
    return topics


def load_topics(path=None):
    path = Path(path or DATA_PATH)
    try:
        with path.open(encoding="utf8") as source:
            return topics_from_json(json.load(source))
    except FileNotFoundError:
        return default_topics()
    except json.JSONDecodeError as error:
        raise ValueError("message-board data is not valid JSON") from error


def save_topics(topics=None, path=None):
    """Atomically replace the on-disk board without exposing a partial file."""
    topics = TOPICS if topics is None else topics
    path = Path(path or DATA_PATH)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent,
        prefix=path.name + ".",
        suffix=".tmp",
    )
    descriptor_open = True
    try:
        with os.fdopen(descriptor, "w", encoding="utf8") as destination:
            descriptor_open = False
            json.dump(
                topics_to_json(topics),
                destination,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )
            destination.write("\n")
            destination.flush()
            os.fsync(destination.fileno())
        os.replace(temporary_name, path)
        temporary_name = None
    finally:
        if descriptor_open:
            os.close(descriptor)
        if temporary_name is not None:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass


def initialize_storage(path=None):
    """Load a complete board, then publish it as the process-wide state."""
    global DATA_PATH, TOPICS, ENTRIES
    selected_path = Path(path or DATA_PATH)
    topics = load_topics(selected_path)
    DATA_PATH = selected_path
    TOPICS = topics
    # Compatibility alias for readers following the original guest-book code.
    ENTRIES = TOPICS["general"]["messages"]


TOPICS = default_topics()
ENTRIES = TOPICS["general"]["messages"]


def cookie_token(cookie_header):
    """Return the token cookie without assuming it is the only cookie."""
    if not cookie_header:
        return None
    for raw_cookie in cookie_header.split(";"):
        name, separator, value = raw_cookie.strip().partition("=")
        if separator and name.casefold() == "token":
            return value
    return None


def delete_expired_sessions(now=None):
    """Drop inactive session records whose browser cookie is no longer valid."""
    now = time.time() if now is None else now
    expired_tokens = [
        token
        for token, record in SESSIONS.items()
        if record["expires_at"] <= now
    ]
    for token in expired_tokens:
        del SESSIONS[token]
    return len(expired_tokens)


def open_session(cookie_header=None, now=None):
    """Return a sliding-expiration session and the matching cookie deadline."""
    now = time.time() if now is None else now
    delete_expired_sessions(now)
    token = cookie_token(cookie_header)
    record = SESSIONS.get(token)
    if record is None:
        while True:
            token = str(random.random())[2:]
            if token not in SESSIONS:
                break
        record = {"data": {}, "expires_at": now + SESSION_LIFETIME_SECONDS}
        SESSIONS[token] = record
    else:
        # Active sessions slide forward. Re-sending the same cookie with this
        # later Expires date exercises browser-side replacement semantics.
        record["expires_at"] = now + SESSION_LIFETIME_SECONDS
    return token, record["data"], record["expires_at"]


def handle_connection(conx, now=None):
    req = conx.makefile("b")
    reqline = req.readline().decode("utf8")
    method, url, version = reqline.split(" ", 2)
    assert method in ["GET", "POST"]
    headers = {}
    while True:
        line = req.readline().decode("utf8")
        if line == "\r\n":
            break
        header, value = line.split(":", 1)
        headers[header.casefold()] = value.strip()
    if "content-length" in headers:
        length = int(headers["content-length"])
        body = req.read(length).decode("utf8")
    else:
        body = None

    token, session, expires_at = open_session(headers.get("cookie"), now)
    status, body = do_request(session, method, url, headers, body)
    encoded_body = body.encode("utf8")

    response = "HTTP/1.0 {}\r\n".format(status)
    response += "Content-Length: {}\r\n".format(len(encoded_body))
    response += "Content-Type: text/html; charset=utf-8\r\n"
    expiration = email.utils.formatdate(expires_at, usegmt=True)
    template = "Set-Cookie: token={}; Expires={}; SameSite=Lax\r\n"
    response += template.format(token, expiration)
    if urllib.parse.urlsplit(url).path.rstrip("/") == "/xhr":
        response += "Access-Control-Allow-Origin: *\r\n"
    request_url = urllib.parse.urlsplit(url)
    if request_url.path.rstrip("/") == "/referrer-policy":
        policy = urllib.parse.parse_qs(request_url.query).get("policy", [""])[0]
        if policy in {"no-referrer", "same-origin"}:
            response += "Referrer-Policy: {}\r\n".format(policy)
    response += "Content-Security-Policy: default-src 'self'\r\n"
    response += "\r\n"
    conx.sendall(response.encode("utf8") + encoded_body)
    conx.close()


def do_request(session, method, url, headers, body):
    request_url = urllib.parse.urlsplit(url)
    path = request_url.path
    if len(path) > 1:
        path = path.rstrip("/")

    if method == "GET" and path == "/":
        return "200 OK", show_home(session)
    elif method == "GET" and path == "/comment.js":
        return serve_tutorial_file("comment9.js")
    elif method == "GET" and path == "/eventloop.js":
        return serve_tutorial_file("eventloop.js")
    elif method == "GET" and path == "/comment.css":
        return serve_tutorial_file("comment9.css")
    elif method == "GET" and path == "/login":
        return "200 OK", login_form(session)
    elif method == "POST" and path == "/":
        return do_login(session, form_decode(body))
    elif method == "POST" and path == "/new-topic":
        return create_topic(session, form_decode(body))
    elif method == "POST" and path == "/add":
        # Backward-compatible endpoint from the original guest book.
        return submit_message(session, "general", form_decode(body))
    elif method == "GET" and path == "/count":
        return "200 OK", show_count()
    elif method == "GET" and path == "/xhr":
        return "200 OK", "XHR OK"
    elif method == "GET" and path == "/xhr-denied":
        return "200 OK", "This response is intentionally not CORS-enabled"
    elif method == "GET" and path == "/referer":
        return "200 OK", show_referer(headers.get("referer"))
    elif method == "GET" and path == "/referrer-policy":
        policy = urllib.parse.parse_qs(request_url.query).get("policy", [""])[0]
        if policy in {"default", "no-referrer", "same-origin"}:
            return "200 OK", show_referrer_policy(policy)

    parts = [urllib.parse.unquote(part) for part in path.split("/") if part]
    if method == "GET" and len(parts) == 1 and parts[0] in TOPICS:
        return "200 OK", show_topic(session, parts[0])
    elif method == "POST" and len(parts) == 2 and parts[1] == "add":
        return submit_message(session, parts[0], form_decode(body))

    return "404 Not Found", not_found(path, method)


def serve_tutorial_file(path):
    try:
        with open(path, encoding="utf8") as source:
            return "200 OK", source.read()
    except FileNotFoundError:
        return "404 Not Found", not_found("/" + path, "GET")


def form_decode(body):
    params = {}
    for field in (body or "").split("&"):
        if not field or "=" not in field:
            continue
        name, value = field.split("=", 1)
        params[urllib.parse.unquote_plus(name)] = urllib.parse.unquote_plus(value)
    return params


def issue_nonce(session):
    nonce = str(random.random())[2:]
    session["nonce"] = nonce
    return nonce


def submission_error(session, params):
    if "user" not in session:
        return "Sign in before changing the message board."
    if params.get("nonce") != session.get("nonce"):
        return "That form has expired. Reload the page and try again."
    return None


def page(title, content):
    return (
        "<!doctype html>"
        "<html><head><title>{}</title>"
        "<style>"
        "body {{ font: 18px sans-serif; max-width: 760px; margin: 32px auto; "
        "padding: 0 16px; background: #f6f3ea; color: #242424; }}"
        "nav, article, form {{ background: white; padding: 14px; margin: 14px 0; }}"
        "li {{ margin: 10px 0; }} input {{ margin: 4px; }}"
        ".notice {{ color: #176b2c; }} .error {{ color: #a11717; }}"
        "small {{ color: #666; }}"
        "</style></head><body>{}</body></html>"
    ).format(html.escape(title), content)


def banner(session):
    if "user" in session:
        return "<nav><a href=/>Zibra Boards</a> | Signed in as <b>{}</b></nav>".format(
            html.escape(session["user"])
        )
    return "<nav><a href=/>Zibra Boards</a> | <a href=/login>Sign in</a></nav>"


def feedback(notice=None, error=None):
    out = ""
    if notice:
        out += '<p class="notice">{}</p>'.format(html.escape(notice))
    if error:
        out += '<p class="error">{}</p>'.format(html.escape(error))
    return out


def show_home(session, notice=None, error=None):
    out = banner(session)
    out += "<h1>Zibra Boards</h1>"
    out += "<p>Pick a topic. Messages stay with the conversation where they were posted.</p>"
    out += feedback(notice, error)
    out += "<ul>"
    for slug, topic in sorted(TOPICS.items(), key=lambda item: item[1]["title"].casefold()):
        count = len(topic["messages"])
        out += '<li><a href="/{}"><b>{}</b></a> - {} <small>({} {})</small></li>'.format(
            slug,
            html.escape(topic["title"]),
            html.escape(topic["description"]),
            count,
            "message" if count == 1 else "messages",
        )
    out += "</ul>"

    if "user" in session:
        nonce = issue_nonce(session)
        out += '<form action="/new-topic" method="post">'
        out += "<h2>Start a new topic</h2>"
        out += '<p><label>Topic name <input name="topic" maxlength="60"></label></p>'
        out += '<p><label>Description <input name="description" maxlength="120"></label></p>'
        out += '<input name="nonce" type="hidden" value="{}">'.format(html.escape(nonce))
        out += "<button>Create topic</button></form>"
    else:
        out += "<p><a href=/login>Sign in</a> to create a topic or post a message.</p>"
    return page("Zibra Boards", out)


def show_topic(session, slug, notice=None, error=None):
    topic = TOPICS[slug]
    out = banner(session)
    out += "<h1>{}</h1>".format(html.escape(topic["title"]))
    out += "<p>{}</p>".format(html.escape(topic["description"]))
    out += '<p><a href="/{}">Permanent link to this topic</a></p>'.format(slug)
    out += '<p><small>Started by {}</small></p>'.format(html.escape(topic["created_by"]))
    out += feedback(notice, error)

    if "user" in session:
        nonce = issue_nonce(session)
        out += '<form action="/{}/add" method="post">'.format(slug)
        out += "<h2>Add a message</h2>"
        out += '<p><input name="message" maxlength="280"></p>'
        out += '<input name="nonce" type="hidden" value="{}">'.format(html.escape(nonce))
        out += "<button>Post to {}</button></form>".format(html.escape(topic["title"]))
    else:
        out += "<p><a href=/login>Sign in</a> to join this topic.</p>"

    out += "<h2>Messages</h2>"
    if not topic["messages"]:
        out += "<p><i>No messages yet. Start the conversation.</i></p>"
    for message, who in topic["messages"]:
        out += "<article><p>{}</p><small>by {}</small></article>".format(
            html.escape(message), html.escape(who)
        )
    return page(topic["title"], out)


def create_topic(session, params):
    error = submission_error(session, params)
    if error:
        return "403 Forbidden", show_home(session, error=error)

    title = params.get("topic", "").strip()
    description = params.get("description", "").strip()
    slug = slugify_topic(title)
    if not title or len(title) > 60 or not slug or slug in RESERVED_TOPIC_SLUGS:
        return "400 Bad Request", show_home(
            session,
            error="Use a topic name containing letters or numbers that is not reserved.",
        )
    if slug in TOPICS:
        return "409 Conflict", show_home(
            session,
            error='A topic named "{}" already exists.'.format(TOPICS[slug]["title"]),
        )
    if len(description) > 120:
        return "400 Bad Request", show_home(
            session, error="Descriptions are limited to 120 characters."
        )

    TOPICS[slug] = {
        "title": title,
        "description": description or "A brand-new conversation.",
        "created_by": session["user"],
        "messages": [],
    }
    try:
        save_topics()
    except OSError:
        del TOPICS[slug]
        return "500 Internal Server Error", show_home(
            session,
            error="The topic could not be saved. Please try again.",
        )
    return "200 OK", show_topic(
        session,
        slug,
        notice='Topic created. Its permanent URL is "/{}".'.format(slug),
    )


def submit_message(session, slug, params):
    if slug not in TOPICS:
        return "404 Not Found", not_found("/" + slug, "POST")
    error = submission_error(session, params)
    if error:
        return "403 Forbidden", show_topic(session, slug, error=error)

    message = (params.get("message") or params.get("guest") or "").strip()
    if not message:
        return "400 Bad Request", show_topic(
            session, slug, error="Messages cannot be empty."
        )
    if len(message) > 280:
        return "400 Bad Request", show_topic(
            session, slug, error="Messages are limited to 280 characters."
        )

    messages = TOPICS[slug]["messages"]
    messages.append((message, session["user"]))
    try:
        save_topics()
    except OSError:
        messages.pop()
        return "500 Internal Server Error", show_topic(
            session,
            slug,
            error="The message could not be saved. Please try again.",
        )
    return "200 OK", show_topic(session, slug, notice="Message posted.")


# Compatibility helpers for readers following the earlier guest-book chapter.
def show_comments(session):
    return show_topic(session, "general")


def add_entry(session, params):
    return submit_message(session, "general", params)


def show_count():
    out = "<!doctype html>"
    out += "<div>"
    out += "  Let's count up to 99!"
    out += "</div>"
    out += "<div>Output</div>"
    out += "<div>XHR result pending</div>"
    out += "<script src=/eventloop.js></script>"
    return out


def show_referer(value):
    shown = value or "(none)"
    return page(
        "Referer received",
        "<h1>Referer received</h1><p id=result>{}</p>".format(html.escape(shown)),
    )


def show_referrer_policy(policy):
    return page(
        "Referrer policy probe",
        (
            "<h1>Referrer-Policy: {policy}</h1>"
            "<p><a href=/referer>Same-origin target</a></p>"
            "<p><a href=http://127.0.0.1:8005/referer>Cross-origin target</a></p>"
            "<p>Open this page through <b>localhost</b>, not 127.0.0.1, "
            "so the second link changes origin.</p>"
        ).format(policy=html.escape(policy)),
    )


def login_form(session):
    del session
    body = banner({})
    body += "<h1>Sign in</h1>"
    body += "<form action=/ method=post>"
    body += "<p>Username: <input name=username></p>"
    body += "<p>Password: <input name=password type=password></p>"
    body += "<p><button>Log in</button></p>"
    body += "</form>"
    return page("Sign in", body)


def do_login(session, params):
    username = params.get("username")
    password = params.get("password")
    if username in LOGINS and LOGINS[username] == password:
        session["user"] = username
        return "200 OK", show_home(session, notice="Welcome back, {}.".format(username))
    return "401 Unauthorized", page(
        "Sign in failed",
        banner({}) + "<h1>Invalid password for {}</h1>".format(html.escape(username or "")),
    )


def not_found(url, method):
    out = "<!doctype html>"
    out += "<h1>{} {} not found!</h1>".format(html.escape(method), html.escape(url))
    out += "<p><a href=/>Return to the topic list</a></p>"
    return out


if __name__ == "__main__":
    initialize_storage()
    s = socket.socket(
        family=socket.AF_INET,
        type=socket.SOCK_STREAM,
        proto=socket.IPPROTO_TCP,
    )
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("", 8005))
    s.listen()
    print("Listening on port 8005...")

    while True:
        conx, addr = s.accept()
        print("Received connection from", addr)
        handle_connection(conx)
