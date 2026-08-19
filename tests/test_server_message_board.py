import copy
import importlib.util
from pathlib import Path
import unittest
import urllib.parse


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("zibra_server", ROOT / "server.py")
server = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(server)
INITIAL_TOPICS = copy.deepcopy(server.TOPICS)


def request(session, method, path, params=None):
    body = urllib.parse.urlencode(params) if params is not None else None
    return server.do_request(session, method, path, {}, body)


class MessageBoardTests(unittest.TestCase):
    def setUp(self):
        server.TOPICS.clear()
        server.TOPICS.update(copy.deepcopy(INITIAL_TOPICS))
        server.ENTRIES = server.TOPICS["general"]["messages"]
        server.SESSIONS.clear()

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


if __name__ == "__main__":
    unittest.main()
