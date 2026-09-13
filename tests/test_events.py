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


if __name__ == "__main__":
    unittest.main(verbosity=0)
