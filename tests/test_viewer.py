#!/usr/bin/env python3
"""Viewer server tests: the security checks, the API, media ranges, markup, exports.

Runs the real server on 127.0.0.1 with a throwaway OF_STATE and raw http.client
requests, so every header (Host, Origin, Sec-Fetch-Site) can be forged the way a
hostile page or a DNS-rebinding attack would.
"""
import sys

sys.dont_write_bytecode = True

import base64  # noqa: E402
import http.client  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import shutil  # noqa: E402
import stat  # noqa: E402
import tempfile  # noqa: E402
import time  # noqa: E402
import unittest  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, os.path.join(ROOT, "lib"))

TMP = tempfile.mkdtemp(prefix="of-viewer-")
os.environ["OF_STATE"] = os.path.join(TMP, "state")
os.environ["OF_RUNTIME"] = os.path.join(TMP, "run")
os.environ["HOME"] = os.path.join(TMP, "home")

import of_db  # noqa: E402
import of_viewer  # noqa: E402

PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")


def make_issue(title="Viewer test", with_replay=True):
    os.makedirs(of_db.issues_dir(), exist_ok=True)
    p = tempfile.mkdtemp(prefix=".pending-", dir=of_db.issues_dir())
    with open(os.path.join(p, "shot.png"), "wb") as f:
        f.write(PNG)
    if with_replay:
        with open(os.path.join(p, "replay.mp4"), "wb") as f:
            f.write(bytes(range(256)) * 4)
        with open(os.path.join(p, "replay.mp4.ts"), "w") as f:
            f.write("monotonic_microsec realtime_microsec\n1000000 %d\n" % (int(time.time() * 1e6) - 5_000_000))
    with open(os.path.join(p, "events.jsonl"), "w") as f:
        t = int(time.time() * 1000)
        f.write(json.dumps({"t": t - 4000, "type": "window", "event": "activewindow", "class": "kitty", "title": "<b>x</b>"}) + "\n")
        f.write(json.dumps({"t": t - 2000, "type": "key", "combo": "Super+Enter"}) + "\n")
    with open(os.path.join(p, "meta.json"), "w") as f:
        json.dump({"title": title, "kind": "bug", "description": "<script>alert(1)</script>", "source": "test",
                   "captureMs": int(time.time() * 1000),
                   "subject": {"type": "plugin", "id": "test.plugin", "name": "Test", "repo": "https://github.com/o/r"}}, f)
    return of_db.create(p)["id"]


class ViewerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv, cls.info = of_viewer.start(version="test", host="127.0.0.1", port=0)
        cls.port = cls.srv.port
        cls.host = "127.0.0.1:%d" % cls.port
        cls.origin = "http://" + cls.host
        cls.token = cls.srv.token
        cls.issue = make_issue()

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.srv.server_close()
        shutil.rmtree(TMP, ignore_errors=True)

    def req(self, method, path, body=None, host=None, token=True, origin=True, site="same-origin", ctype="application/json", extra=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        headers = {"Host": host or self.host}
        if token:
            headers["X-Feedback-Token"] = self.token if token is True else token
        if origin:
            headers["Origin"] = self.origin if origin is True else origin
        if site:
            headers["Sec-Fetch-Site"] = site
        data = None
        if body is not None:
            data = json.dumps(body).encode() if not isinstance(body, bytes) else body
            headers["Content-Type"] = ctype
        headers.update(extra or {})
        c.request(method, path, body=data, headers=headers)
        r = c.getresponse()
        payload = r.read()
        c.close()
        return r, payload

    # -- the fence
    def test_token_file_private(self):
        mode = stat.S_IMODE(os.stat(os.path.join(os.environ["OF_STATE"], "viewer.token")).st_mode)
        self.assertEqual(mode, 0o600)
        self.assertGreaterEqual(len(self.token), 32)

    def test_wrong_host_is_421_everywhere(self):
        for path in ("/", "/app.js", "/api/issues", "/media/1/shot.png"):
            r, _ = self.req("GET", path, host="evil.example:%d" % self.port)
            self.assertEqual(r.status, 421, path)
        r, _ = self.req("PATCH", "/api/issues/%d" % self.issue, {"title": "x"}, host="localhost:%d" % self.port)
        self.assertEqual(r.status, 421)

    def test_api_needs_token(self):
        r, _ = self.req("GET", "/api/issues", token=False)
        self.assertEqual(r.status, 401)
        r, _ = self.req("GET", "/api/issues", token="nope" * 10)
        self.assertEqual(r.status, 401)
        r, body = self.req("GET", "/api/issues")
        self.assertEqual(r.status, 200)
        self.assertIn(self.issue, [i["id"] for i in json.loads(body)])

    def test_shell_without_token_carries_no_data(self):
        r, body = self.req("GET", "/", token=False)
        self.assertEqual(r.status, 200)
        self.assertNotIn(b"Viewer test", body)
        self.assertIn("default-src 'self'", r.getheader("Content-Security-Policy"))
        self.assertIsNone(r.getheader("Access-Control-Allow-Origin"))
        r, _ = self.req("GET", "/theme.css", token=False)
        self.assertEqual(r.status, 200)

    def test_cross_site_mutations_refused(self):
        path = "/api/issues/%d" % self.issue
        for kw in ({"site": "cross-site"}, {"site": None}, {"origin": "http://evil.example"}, {"origin": None},
                   {"ctype": "text/plain"}):
            r, _ = self.req("PATCH", path, {"title": "pwned"}, **kw)
            self.assertEqual(r.status, 403, kw)
        self.assertEqual(of_db.get_issue(self.issue)["title"], "Viewer test")
        r, _ = self.req("PATCH", path, {"title": "pwned"}, token=False)
        self.assertEqual(r.status, 401)

    def test_no_delete_or_put(self):
        r, _ = self.req("DELETE", "/api/issues/%d" % self.issue)
        self.assertEqual(r.status, 405)
        self.assertIsNotNone(of_db.get_issue(self.issue))

    # -- the API
    def test_patch_and_validation(self):
        path = "/api/issues/%d" % self.issue
        r, body = self.req("PATCH", path, {"notes": "Seen twice", "status": "triaged"})
        self.assertEqual(r.status, 200, body)
        i = of_db.get_issue(self.issue)
        self.assertEqual((i["notes"], i["status"]), ("Seen twice", "triaged"))
        self.assertEqual(i["status_log"][-1]["by"], "viewer")
        r, _ = self.req("PATCH", path, {"status": "deleted-lol"})
        self.assertEqual(r.status, 400)
        r, _ = self.req("PATCH", path, {"title": 42})
        self.assertEqual(r.status, 400)
        r, _ = self.req("PATCH", path, b"not json", ctype="application/json")
        self.assertEqual(r.status, 400)
        r, _ = self.req("PATCH", "/api/issues/99999", {"notes": "x"})
        self.assertEqual(r.status, 404)

    def test_issue_payload_and_events(self):
        r, body = self.req("GET", "/api/issues/%d" % self.issue)
        i = json.loads(body)
        self.assertNotIn("dir", i)
        replay = [a for a in i["attachments"] if a["kind"] == "replay"][0]
        self.assertTrue(replay["url"].startswith("/media/%d/replay.mp4?exp=" % self.issue))
        self.assertIn("firstFrameMs", replay["meta"])
        r, body = self.req("GET", "/api/issues/%d/events" % self.issue)
        evs = json.loads(body)
        self.assertEqual([e["type"] for e in evs], ["window", "key"])
        self.assertEqual(evs[1]["label"], "key Super+Enter")

    # -- media
    def media_url(self, name):
        _, body = self.req("GET", "/api/issues/%d" % self.issue)
        return [a["url"] for a in json.loads(body)["attachments"] if a["path"] == name][0]

    def test_media_signature_expiry_and_ranges(self):
        url = self.media_url("replay.mp4")
        r, body = self.req("GET", url, token=False, origin=False, site=None)
        self.assertEqual((r.status, len(body)), (200, 1024))
        self.assertEqual(r.getheader("Content-Type"), "video/mp4")
        r, body = self.req("GET", url, token=False, extra={"Range": "bytes=10-19"})
        self.assertEqual((r.status, body, r.getheader("Content-Range")), (206, bytes(range(10, 20)), "bytes 10-19/1024"))
        r, body = self.req("GET", url, token=False, extra={"Range": "bytes=-4"})
        self.assertEqual((r.status, len(body)), (206, 4))
        r, _ = self.req("GET", url, token=False, extra={"Range": "bytes=5000-"})
        self.assertEqual(r.status, 416)
        bad = url[:-4] + ("0000" if not url.endswith("0000") else "1111")
        r, _ = self.req("GET", bad, token=False)
        self.assertEqual(r.status, 403)
        expired = of_viewer.sign(self.token, "/media/%d/replay.mp4" % self.issue, int(time.time()) - 5)
        r, _ = self.req("GET", "/media/%d/replay.mp4?exp=%d&sig=%s" % (self.issue, int(time.time()) - 5, expired), token=False)
        self.assertEqual(r.status, 403)
        # A valid signature for a file that is not an attachment of the issue.
        path = "/media/%d/meta.json" % self.issue
        exp = int(time.time()) + 60
        r, _ = self.req("GET", "%s?exp=%d&sig=%s" % (path, exp, of_viewer.sign(self.token, path, exp)), token=False)
        self.assertEqual(r.status, 404)
        r, _ = self.req("GET", "/media/%d/..%%2Ffeedback.db?exp=%d&sig=x" % (self.issue, exp), token=False)
        self.assertEqual(r.status, 403)

    # -- markup and exports
    def test_markup_saved_and_attached(self):
        png = "data:image/png;base64," + base64.b64encode(PNG).decode()
        r, body = self.req("POST", "/api/issues/%d/markup" % self.issue,
                           {"base": "shot.png", "shapes": [{"type": "arrow", "x1": 1, "y1": 1, "x2": 5, "y2": 5}], "png": png})
        self.assertEqual(r.status, 200, body)
        i = of_db.get_issue(self.issue)
        m = [a for a in i["attachments"] if a["kind"] == "markup"]
        self.assertEqual(m[-1]["path"], "markup-1.png")
        with open(os.path.join(i["dir"], "markup-1.json")) as f:
            self.assertEqual(json.load(f)["shapes"][0]["type"], "arrow")
        r, _ = self.req("POST", "/api/issues/%d/markup" % self.issue, {"shapes": [], "png": "data:image/png;base64,AAAA"})
        self.assertEqual(r.status, 400)
        r, _ = self.req("POST", "/api/issues/%d/markup" % self.issue, {"shapes": [], "png": png}, site="cross-site")
        self.assertEqual(r.status, 403)

    def test_markdown_export(self):
        r, body = self.req("GET", "/api/issues/%d/export.md" % self.issue)
        self.assertEqual(r.status, 200)
        self.assertIn("attachment", r.getheader("Content-Disposition"))
        self.assertIn(b"# Viewer test", body)

    def test_print_html_escapes(self):
        doc = of_viewer.print_html(self.issue)
        self.assertNotIn("<script>alert(1)</script>", doc)
        self.assertIn("&lt;script&gt;", doc)
        self.assertNotIn("<b>x</b>", doc)

    def test_pdf_export_with_stub(self):
        stub = os.path.join(TMP, "fake-chromium")
        with open(stub, "w") as f:
            f.write("#!/bin/bash\nfor a; do case $a in --print-to-pdf=*) printf '%%PDF-1.4 fake' >\"${a#--print-to-pdf=}\";; esac; done\n")
        os.chmod(stub, 0o755)
        os.environ["OF_CHROMIUM"] = stub
        try:
            r, body = self.req("GET", "/api/issues/%d/export.pdf" % self.issue)
        finally:
            os.environ.pop("OF_CHROMIUM", None)
        self.assertEqual(r.status, 200, body[:200])
        self.assertEqual(r.getheader("Content-Type"), "application/pdf")
        self.assertTrue(body.startswith(b"%PDF"))

    def test_handoff_request_only_records(self):
        r, body = self.req("POST", "/api/issues/%d/handoff" % self.issue, {"target": "shell; rm -rf ~"})
        self.assertEqual(r.status, 400)
        self.assertEqual(of_db.get_issue(self.issue)["handoffs"], [])


if __name__ == "__main__":
    unittest.main(verbosity=0)
