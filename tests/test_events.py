#!/usr/bin/env python3
"""Unit tests for the rolling log, the key decoder and Hyprland line parsing."""
import sys

sys.dont_write_bytecode = True

import json  # noqa: E402
import os  # noqa: E402
import tempfile  # noqa: E402
import unittest  # noqa: E402

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import of_events  # noqa: E402
import of_keys  # noqa: E402
import of_subject  # noqa: E402

MIN = 60000


class SegmentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.seg = os.path.join(self.tmp.name, "seg")

    def tearDown(self):
        self.tmp.cleanup()

    def test_rotation_and_prune(self):
        log = of_events.SegmentLog(self.seg, keep_minutes=3)
        base = 29000000 * MIN
        for m in range(6):
            log.write({"t": base + m * MIN + 5, "type": "window", "event": "activewindow"})
        log.close()
        kept = sorted(int(n[:-6]) for n in os.listdir(self.seg))
        self.assertEqual(kept, [29000003, 29000004, 29000005])
        self.assertEqual(oct(os.stat(self.seg).st_mode & 0o777), "0o700")
        for n in os.listdir(self.seg):
            self.assertEqual(oct(os.stat(os.path.join(self.seg, n)).st_mode & 0o777), "0o600")

    def test_snapshot_window_and_partial_line(self):
        log = of_events.SegmentLog(self.seg, keep_minutes=12)
        base = 29000000 * MIN
        for i in range(10):
            log.write({"t": base + i * MIN, "type": "key", "combo": "Super+%d" % i})
        log.close()
        # A line still being written (no newline) must be skipped.
        with open(os.path.join(self.seg, "%d.jsonl" % (base // MIN + 9)), "a") as f:
            f.write('{"t": %d, "type": "key"' % (base + 9 * MIN + 1))
        dest = os.path.join(self.tmp.name, "issue", "events.jsonl")
        n = of_events.snapshot(self.seg, dest, minutes=3, now=base + 9 * MIN + 10)
        evs = of_events.read_events(dest)
        self.assertEqual(n, 3)  # minutes 7, 8, 9; minute 6 is 10 ms before the window
        self.assertEqual([e["combo"] for e in evs], ["Super+7", "Super+8", "Super+9"])

    def test_snapshot_empty(self):
        dest = os.path.join(self.tmp.name, "e.jsonl")
        self.assertEqual(of_events.snapshot(os.path.join(self.tmp.name, "none"), dest, 10), 0)
        self.assertTrue(os.path.exists(dest))


class DecoderTests(unittest.TestCase):
    def feed(self, lines):
        d = of_keys.KeyDecoder()
        out = []
        for line in lines:
            out += d.feed(line)
        return out

    def test_redacted_text_and_shortcuts(self):
        evs = self.feed([
            "K ? 1 0", "K ? 0 0",                   # typed letter: redacted press, release dropped
            "K 133 1 0", "K 36 1 0", "K 36 0 0", "K 133 0 0",   # Super+Enter
            "K 37 1 0", "K 54 1 0", "K 54 0 0", "K 37 0 0",     # Ctrl+C
            "K 133 1 0", "K 133 0 0",                          # lone Super tap
            "S resize",
        ])
        self.assertEqual([e.get("combo") or e.get("name") for e in evs],
                         [of_keys.REDACTED, "Super+Enter", "Ctrl+C", "Super", "resize"])
        self.assertTrue(evs[0]["redacted"])
        self.assertTrue(evs[3]["tap"])
        self.assertNotIn("redacted", evs[1])

    def test_garbage_lines(self):
        self.assertEqual(self.feed(["", "K", "K x 1", "Z 1 2"]), [])


class HyprTests(unittest.TestCase):
    def test_parse(self):
        ev = of_events.parse_hypr_line("activewindow>>org.omarchy.agent,Rix · chat", t=1, mono=2)
        self.assertEqual((ev["type"], ev["class"], ev["title"]), ("window", "org.omarchy.agent", "Rix · chat"))
        self.assertEqual(of_events.parse_hypr_line("openlayer>>omarchy-bar")["namespace"], "omarchy-bar")
        self.assertIsNone(of_events.parse_hypr_line("mouse>>whatever"))
        self.assertIsNone(of_events.parse_hypr_line("garbage"))

    def test_locked(self):
        self.assertTrue(of_events.session_locked([{"solitaryBlockedBy": ["WINDOWED", "LOCK"]}]))
        self.assertFalse(of_events.session_locked([{"solitaryBlockedBy": ["WINDOWED"]}, {}]))
        self.assertFalse(of_events.session_locked(None))

    def test_describe(self):
        self.assertEqual(of_events.describe({"type": "key", "combo": "Super+Enter"}), "key Super+Enter")
        self.assertIn("hidden", of_events.describe({"type": "key", "combo": "•", "redacted": True}))
        self.assertEqual(of_events.describe({"type": "layer", "event": "openlayer", "namespace": "omarchy-menu"}),
                         "show omarchy-menu")

    def test_lua_paths(self):
        with self.assertRaises(ValueError):
            of_keys.lua_arm('/tmp/x"; os.execute("boom")')
        self.assertIn("_G.ofrec", of_keys.lua_arm("/run/user/1000/omarchy-feedback/keys.raw"))


class TimelineTests(unittest.TestCase):
    def test_collapses_noise(self):
        import of_report
        raw = [
            {"type": "key", "redacted": True, "combo": "•"},
            {"type": "key", "redacted": True, "combo": "•"},
            {"type": "key", "combo": "Enter"},
            {"type": "window", "event": "activewindow", "class": "kitty", "title": "a", "retitle": True},
            {"type": "window", "event": "activewindow", "class": "kitty", "title": "b", "retitle": True},
            {"type": "screencast", "event": "screencast", "data": "1,monitor"},
            {"type": "screencast", "event": "screencast", "data": "0,monitor"},
            {"type": "key", "redacted": True, "combo": "•"},
        ]
        evs = [{"seq": n, "t": 1000 + n * 100, "type": e["type"], "label": of_events.describe(e), "data": e}
               for n, e in enumerate(raw)]
        orig = of_report.of_db.get_events
        of_report.of_db.get_events = lambda _id: evs
        try:
            lines, total = of_report.timeline({"id": 1, "capture_t_ms": 2000}, 50)
        finally:
            of_report.of_db.get_events = orig
        labels = [line.split("  ", 1)[1] for line in lines]
        self.assertEqual(labels, ["typed 2 keys (text hidden)", "key Enter", "title kitty — b",
                                  "screenshot (monitor)", "typed 1 key (text hidden)"])
        self.assertEqual(total, 8)


def fake(prefix, body):
    """Secret-shaped test values are assembled at runtime so the repository holds no literal key patterns."""
    return prefix[:2] + prefix[2:] + body


class RedactTests(unittest.TestCase):
    def setUp(self):
        import of_redact
        self.r = of_redact

    def check(self, text, kind, secret_part, alert=True):
        clean, found = self.r.redact(text)
        self.assertNotIn(secret_part, clean, text)
        self.assertTrue(any(f["kind"] == kind and f["alert"] == alert for f in found), (text, found))
        again, found2 = self.r.redact(clean)
        self.assertEqual((again, found2), (clean, []), "redact must be idempotent")
        for f in found:
            self.assertNotIn(secret_part, f["masked"])
        return clean

    def test_known_formats_keep_only_the_ends(self):
        gh = fake("ghp_", "aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5")
        clean = self.check("token " + gh, "GitHub token", gh[6:-6])
        self.assertIn("ghp_…3zA5", clean)
        self.check("ANTHROPIC_API_KEY=" + fake("sk-ant-", "api03-Zx9Yw8Vu7Ts6Rq5Po4Nm3Lk2Ji1Hg0Fe"), "Anthropic key", "Zx9Yw8Vu7Ts6")
        self.check("key " + fake("AK", "IAIOSFODNN7EXAMPLE"), "AWS access key", "IOSFODNN7EXA")
        self.check("slack " + fake("xo", "xb-1234567890-abcdefghijkl"), "Slack token", "1234567890-abcd")
        self.check("jwt " + fake("ey", "JhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n"),
                   "JSON web token", "eyJzdWIiOiIxMjM0")

    def test_passwords_become_stars(self):
        self.assertEqual(self.check("mysql --password=hunter2secret -u root", "password", "hunter2"),
                         "mysql --password=******** -u root")
        self.assertEqual(self.check("Password: correct horse battery", "password", "horse"), "Password: ********")
        self.assertEqual(self.check("git clone https://me:s3cretPass@example.com/r.git", "password in a URL", "s3cretPass"),
                         "git clone https://me:********@example.com/r.git")
        self.check("client_secret: " + "Qw3rTy8uIoP1aSdF", "secret", "Qw3rTy8uIoP1")

    def test_account_numbers(self):
        self.assertIn("4111…1111", self.check("card 4111 1111 1111 1111", "card number", "1111 1111 1111"))
        self.check("IBAN DE89 3704 0044 0532 0130 00", "bank account (IBAN)", "3704 0044 0532")
        self.check("SSN 123-45-6789", "ID number", "45-67")
        clean = self.check("order 000123456789", "account or ID number", "0123456", alert=False)
        self.assertIn("…", clean)
        self.assertFalse([f for f in self.r.redact("card 4111 1111 1111 1112")[1] if f["alert"]])   # fails Luhn: not a card

    def test_ids_are_shortened_without_alarm(self):
        self.check("session 550e8400-e29b-41d4-a716-446655440000", "identifier", "e29b-41d4", alert=False)
        self.check("commit 3f786850e387550fdab836ed7e6dc881de23001b", "identifier", "e387550fdab8", alert=False)

    def test_ordinary_text_is_untouched(self):
        for t in ("~/Work/omarchy-feedback — nvim", "Omarchy Help", "Rix · chat", "Password reset page - Firefox",
                  "Feedback 0.4.1 released 2026-09-14 at 23:07:15", "5566f3e0a7e0", "Pinned 1789272421918",
                  "/tmp/tmp.poLeX7aB9q/state/omarchy-feedback/issues/5/shot.png",
                  "OmarchyFans-omarchy-fans-feedback-history-2026-09-13", "chrome-github.com__OmarchyFans-Default",
                  "Super+Ctrl+Shift+L", "token budget exceeded", "the api key is in 1Password"):
            self.assertEqual(self.r.redact(t), (t, []), t)

    def test_objects_skip_structure(self):
        gh = fake("ghp_", "aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5")
        obj, found = self.r.redact_obj({"class": "kitty", "title": "echo " + gh, "address": "5566f3e0a7e0", "list": [gh]})
        self.assertEqual(obj["class"], "kitty")
        self.assertNotIn(gh, json.dumps(obj))
        self.assertEqual(len(found), 1)

    def test_window_titles_are_redacted_at_the_socket(self):
        gh = fake("ghp_", "aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5")
        ev = of_events.parse_hypr_line("activewindow>>kitty,export GITHUB_TOKEN=" + gh + " " + "x" * 300, t=1, mono=1)
        self.assertNotIn(gh[6:-6], json.dumps(ev))
        self.assertEqual(ev["secrets"][0]["kind"], "GitHub token")
        self.assertLessEqual(len(ev["title"]), 200)


class SubjectTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        plugins = os.path.join(self.tmp.name, "plugins")
        for pid, name in (("a.help", "Omarchy Help"), ("b.calc", "Calc")):
            os.makedirs(os.path.join(plugins, pid))
            with open(os.path.join(plugins, pid, "manifest.json"), "w") as f:
                json.dump({"id": pid, "name": name, "version": "1.0"}, f)
        self.pending = os.path.join(self.tmp.name, "pending")
        os.makedirs(self.pending)
        self.env = os.environ.get("OF_PLUGINS_DIR")
        os.environ["OF_PLUGINS_DIR"] = plugins

    def tearDown(self):
        if self.env is None:
            os.environ.pop("OF_PLUGINS_DIR", None)
        else:
            os.environ["OF_PLUGINS_DIR"] = self.env
        self.tmp.cleanup()

    def order(self, win):
        with open(os.path.join(self.pending, "activewindow.json"), "w") as f:
            json.dump(win, f)
        return [(c["type"], c["id"]) for c in of_subject.candidates(self.pending)]

    def test_plugin_window_is_the_plugin(self):
        got = self.order({"class": "org.quickshell", "title": "Omarchy Help"})
        self.assertEqual(got[0], ("plugin", "a.help"))
        self.assertEqual(got[1], ("omarchy", "omarchy"))
        self.assertEqual(got.count(("plugin", "a.help")), 1)

    def test_unnamed_shell_window_is_omarchy(self):
        self.assertEqual(self.order({"class": "org.quickshell", "title": "Settings"})[0], ("omarchy", "omarchy"))

    def test_app_window_stays_app(self):
        self.assertEqual(self.order({"class": "firefox", "title": "Calc"})[0], ("app", "firefox"))


if __name__ == "__main__":
    unittest.main(verbosity=0)
