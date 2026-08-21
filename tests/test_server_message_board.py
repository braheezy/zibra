import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
import urllib.parse


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("zibra_server", ROOT / "server.py")
server = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(server)


def request(session, method, path, params=None):
    body = urllib.parse.urlencode(params) if params is not None else None
    return server.do_request(session, method, path, {}, body)


class MemoryConnection:
    def __init__(self, request_bytes):
        self.request = io.BytesIO(request_bytes)
        self.response = b""
        self.closed = False

    def makefile(self, mode):
        self.assert_binary_mode = mode
        return self.request

    def sendall(self, data):
        self.response += data

    def close(self):
        self.closed = True


class MessageBoardTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        server.DATA_PATH = Path(self.temporary_directory.name) / "message_board.json"
        server.TOPICS = server.default_topics()
        server.ENTRIES = server.TOPICS["general"]["messages"]
        server.SESSIONS.clear()

    def tearDown(self):
        self.temporary_directory.cleanup()

    def test_sessions_store_and_refresh_their_cookie_expiration(self):
        token, session, first_expiration = server.open_session(now=1_000)
        self.assertEqual(1_000 + server.SESSION_LIFETIME_SECONDS, first_expiration)
        self.assertIs(session, server.SESSIONS[token]["data"])
        self.assertEqual(first_expiration, server.SESSIONS[token]["expires_at"])

        session["user"] = "a"
        same_token, same_session, later_expiration = server.open_session(
            "unrelated=x; token={}; another=y".format(token),
            now=2_000,
        )
        self.assertEqual(token, same_token)
        self.assertIs(session, same_session)
        self.assertEqual("a", same_session["user"])
        self.assertGreater(later_expiration, first_expiration)
        self.assertEqual(later_expiration, server.SESSIONS[token]["expires_at"])

    def test_expired_sessions_are_deleted_before_cookie_lookup(self):
        server.SESSIONS.update(
            {
                "expired": {"data": {"user": "a"}, "expires_at": 99},
                "live": {"data": {"user": "b"}, "expires_at": 101},
            }
        )

        self.assertEqual(1, server.delete_expired_sessions(now=100))
        self.assertNotIn("expired", server.SESSIONS)
        self.assertIn("live", server.SESSIONS)

        replacement, _, _ = server.open_session("token=expired", now=100)
        self.assertNotEqual("expired", replacement)
        self.assertNotIn("expired", server.SESSIONS)
        self.assertIn(replacement, server.SESSIONS)

    def test_http_response_resends_cookie_with_matching_expires_date(self):
        connection = MemoryConnection(b"GET / HTTP/1.0\r\nHost: localhost\r\n\r\n")
        server.handle_connection(connection, now=1_000)

        response = connection.response.decode("utf8")
        token = next(iter(server.SESSIONS))
        expiration = server.SESSIONS[token]["expires_at"]
        self.assertIn(
            "Set-Cookie: token={}; Expires={}; SameSite=Lax\r\n".format(
                token,
                server.email.utils.formatdate(expiration, usegmt=True),
            ),
            response,
        )
        self.assertTrue(connection.closed)

    def test_xhr_endpoint_opts_into_cross_origin_reads(self):
        connection = MemoryConnection(
            b"GET /xhr HTTP/1.0\r\n"
            b"Host: localhost\r\n"
            b"Origin: http://127.0.0.1:8000\r\n\r\n"
        )
        server.handle_connection(connection, now=1_000)

        headers, body = connection.response.split(b"\r\n\r\n", 1)
        self.assertIn(b"Access-Control-Allow-Origin: *\r\n", headers + b"\r\n")
        self.assertEqual(b"XHR OK", body)

    def test_referrer_policy_probe_emits_policy_and_echoes_referer(self):
        connection = MemoryConnection(
            b"GET /referrer-policy?policy=no-referrer HTTP/1.0\r\n"
            b"Host: localhost:8005\r\n\r\n"
        )
        server.handle_connection(connection, now=1_000)
        headers, body = connection.response.split(b"\r\n\r\n", 1)
        self.assertIn(b"Referrer-Policy: no-referrer\r\n", headers + b"\r\n")
        self.assertIn(b"Same-origin target", body)
        self.assertIn(b"Cross-origin target", body)

        status, echoed = server.do_request(
            {},
            "GET",
            "/referer",
            {"referer": "http://localhost:8005/source?private=yes"},
            None,
        )
        self.assertEqual("200 OK", status)
        self.assertIn("http://localhost:8005/source?private=yes", echoed)

        _, absent = server.do_request({}, "GET", "/referer", {}, None)
        self.assertIn("(none)", absent)

    def test_home_lists_each_topic_at_its_own_url(self):
        status, body = request({}, "GET", "/")

        self.assertEqual("200 OK", status)
        self.assertIn('href="/cooking"', body)
        self.assertIn('href="/cars"', body)
        self.assertIn("Cooking", body)
        self.assertIn("Cars", body)

    def test_messages_are_isolated_by_topic(self):
        session = {"user": "a", "nonce": "valid"}
        status, response = request(
            session,
            "POST",
            "/cooking/add",
            {"message": "Always salt the pasta water.", "nonce": "valid"},
        )

        self.assertEqual("200 OK", status)
        self.assertIn("Always salt the pasta water.", response)
        _, cooking = request(session, "GET", "/cooking")
        _, cars = request(session, "GET", "/cars")
        self.assertIn("Always salt the pasta water.", cooking)
        self.assertNotIn("Always salt the pasta water.", cars)

    def test_authenticated_user_can_create_and_revisit_a_topic(self):
        session = {"user": "a", "nonce": "valid"}
        status, created = request(
            session,
            "POST",
            "/new-topic",
            {
                "topic": "Space & Science",
                "description": "Telescopes, rockets, and wonderfully strange rocks.",
                "nonce": "valid",
            },
        )

        self.assertEqual("200 OK", status)
        self.assertIn("space-science", server.TOPICS)
        self.assertIn('permanent URL is &quot;/space-science&quot;', created)
        self.assertEqual("a", server.TOPICS["space-science"]["created_by"])

        status, topic = request(session, "GET", "/space-science")
        self.assertEqual("200 OK", status)
        self.assertIn("Space &amp; Science", topic)
        _, home = request(session, "GET", "/")
        self.assertIn('href="/space-science"', home)

    def test_topic_and_message_mutations_require_login_and_current_nonce(self):
        status, _ = request(
            {},
            "POST",
            "/new-topic",
            {"topic": "Unauthorized", "nonce": "anything"},
        )
        self.assertEqual("403 Forbidden", status)
        self.assertNotIn("unauthorized", server.TOPICS)

        session = {"user": "a", "nonce": "current"}
        before = list(server.TOPICS["cars"]["messages"])
        status, _ = request(
            session,
            "POST",
            "/cars/add",
            {"message": "This must not land.", "nonce": "stale"},
        )
        self.assertEqual("403 Forbidden", status)
        self.assertEqual(before, server.TOPICS["cars"]["messages"])

    def test_user_content_is_escaped_and_reserved_topic_names_are_rejected(self):
        session = {"user": "a", "nonce": "current"}
        status, created = request(
            session,
            "POST",
            "/new-topic",
            {
                "topic": "Fish <b> & Chips",
                "description": "<script>not executable</script>",
                "nonce": "current",
            },
        )
        self.assertEqual("200 OK", status)
        self.assertIn("Fish &lt;b&gt; &amp; Chips", created)
        self.assertIn("&lt;script&gt;not executable&lt;/script&gt;", created)
        self.assertNotIn("<script>not executable</script>", created)

        session["nonce"] = "next"
        status, _ = request(
            session,
            "POST",
            "/new-topic",
            {"topic": "Login", "nonce": "next"},
        )
        self.assertEqual("400 Bad Request", status)
        self.assertNotIn("login", server.TOPICS)

    def test_topics_and_messages_survive_a_simulated_restart(self):
        session = {"user": "a", "nonce": "create"}
        status, _ = request(
            session,
            "POST",
            "/new-topic",
            {
                "topic": "Persistence",
                "description": "State that outlives the process.",
                "nonce": "create",
            },
        )
        self.assertEqual("200 OK", status)

        status, _ = request(
            session,
            "POST",
            "/persistence/add",
            {"message": "Still here after restart.", "nonce": session["nonce"]},
        )
        self.assertEqual("200 OK", status)
        self.assertTrue(server.DATA_PATH.is_file())

        server.TOPICS = server.default_topics()
        server.ENTRIES = server.TOPICS["general"]["messages"]
        server.initialize_storage(server.DATA_PATH)

        self.assertIn("persistence", server.TOPICS)
        self.assertEqual(
            [("Still here after restart.", "a")],
            server.TOPICS["persistence"]["messages"],
        )
        status, topic = request({}, "GET", "/persistence")
        self.assertEqual("200 OK", status)
        self.assertIn("Still here after restart.", topic)

    def test_invalid_storage_is_rejected_without_replacing_live_state(self):
        server.DATA_PATH.write_text('{"version": 99, "topics": {}}', encoding="utf8")
        live_topics = server.TOPICS

        with self.assertRaisesRegex(ValueError, "version"):
            server.initialize_storage(server.DATA_PATH)

        self.assertIs(live_topics, server.TOPICS)
        self.assertEqual(
            '{"version": 99, "topics": {}}',
            server.DATA_PATH.read_text(encoding="utf8"),
        )

    def test_failed_writes_roll_back_in_memory_mutations(self):
        server.DATA_PATH = Path(self.temporary_directory.name)
        session = {"user": "a", "nonce": "topic"}

        status, response = request(
            session,
            "POST",
            "/new-topic",
            {"topic": "Must Roll Back", "nonce": "topic"},
        )
        self.assertEqual("500 Internal Server Error", status)
        self.assertNotIn("must-roll-back", server.TOPICS)
        self.assertIn("could not be saved", response)

        before = list(server.TOPICS["cars"]["messages"])
        session["nonce"] = "message"
        status, response = request(
            session,
            "POST",
            "/cars/add",
            {"message": "Do not retain me.", "nonce": "message"},
        )
        self.assertEqual("500 Internal Server Error", status)
        self.assertEqual(before, server.TOPICS["cars"]["messages"])
        self.assertIn("could not be saved", response)


if __name__ == "__main__":
    unittest.main()
