#!/usr/bin/env python3
"""The local web viewer: an HTTP server on loopback, run by the feedback daemon.

  of_viewer.py serve                 run it on its own (tests; the daemon runs it in a thread)
  of_viewer.py pdf <id> <out.pdf>    render the print view to PDF with headless Chromium
  of_viewer.py url [id]              the URL to open (token in the fragment, never sent to the server)
  of_viewer.py print-html <id>       the print view HTML (debugging)

Security model. Any web page in the browser can reach a loopback server, so:
  - the Host header must be exactly the viewer's host:port (defeats DNS rebinding) -> 421;
  - every /api request needs the per-machine token (header X-Feedback-Token) -> 401;
  - mutations also need Sec-Fetch-Site: same-origin, Origin equal to the viewer's
    origin and a JSON body -> 403 (no CORS headers are ever sent);
  - media (<video>, <img>) use short-lived HMAC-signed URLs instead of the token;
  - the page cannot delete issues or start agents: a hand-off from the viewer only
    records a request that the desktop confirms (notification or the bar panel).
The app shell (HTML/JS/CSS) carries no data and is served without the token.
"""
import sys

sys.dont_write_bytecode = True

import base64  # noqa: E402
import hashlib  # noqa: E402
import hmac  # noqa: E402
import html  # noqa: E402
import http.server  # noqa: E402
import json  # noqa: E402
import mimetypes  # noqa: E402
import os  # noqa: E402
import re  # noqa: E402
import secrets  # noqa: E402
import shutil  # noqa: E402
import socketserver  # noqa: E402
import subprocess  # noqa: E402
import tempfile  # noqa: E402
import threading  # noqa: E402
import time  # noqa: E402
import urllib.parse  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import of_db  # noqa: E402
import of_events  # noqa: E402
import of_redact  # noqa: E402
import of_report  # noqa: E402
import of_secrets  # noqa: E402

WEB = os.path.join(os.path.dirname(HERE), "web")
CLI = os.path.join(os.path.dirname(HERE), "bin", "omarchy-feedback")
DEFAULT_HOST, DEFAULT_PORT = "127.79.33.1", 7741
MAX_BODY = 25 * 1024 * 1024
MEDIA_TTL = 6 * 3600
STATIC = {"/": "index.html", "/index.html": "index.html", "/app.js": "app.js", "/app.css": "app.css",
          "/sw.js": "sw.js", "/manifest.webmanifest": "manifest.webmanifest", "/icon.svg": "icon.svg",
          "/icon.png": "icon.png", "/icon-192.png": "icon-192.png", "/icon-512.png": "icon-512.png"}
CSP = ("default-src 'self'; img-src 'self' data: blob:; media-src 'self' blob:; style-src 'self'; "
       "script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")


def runtime_dir():
    return os.environ.get("OF_RUNTIME") or os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "omarchy-feedback")


def token():
    path = os.path.join(of_db.state_dir(), "viewer.token")
    try:
        with open(path) as f:
            t = f.read().strip()
            if len(t) >= 32:
                return t
    except OSError:
        pass
    os.makedirs(of_db.state_dir(), mode=0o700, exist_ok=True)
    t = secrets.token_urlsafe(32)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(t)
    return t


def sign(tok, path, exp):
    return hmac.new(tok.encode(), ("%s|%d" % (path, exp)).encode(), hashlib.sha256).hexdigest()[:40]


def signed(tok, path, ttl=MEDIA_TTL):
    exp = int(time.time()) + ttl
    return "%s?exp=%d&sig=%s" % (urllib.parse.quote(path), exp, sign(tok, path, exp))


def theme_css():
    """CSS variables from Omarchy's current theme (colors.toml), with fallbacks."""
    colors = {}
    path = os.path.join(os.path.expanduser("~"), ".local", "state", "omarchy", "current", "theme", "colors.toml")
    try:
        import tomllib
        with open(path, "rb") as f:
            colors = tomllib.load(f)
    except (OSError, ValueError, ImportError):
        colors = {}
    ok = lambda v: isinstance(v, str) and re.fullmatch(r"#[0-9A-Fa-f]{3,8}", v)  # noqa: E731
    pick = lambda k, d: colors.get(k) if ok(colors.get(k)) else d  # noqa: E731
    vars_ = {"bg": pick("background", "#111418"), "bg2": pick("lighter_background", "#1d2228"),
             "bg0": pick("dark_background", "#0c0f12"), "fg": pick("foreground", "#d8dee9"),
             "muted": pick("muted", "#6b7785"), "accent": pick("accent", "#7aa2f7"),
             "sel": pick("selection", "#2a3340"), "red": pick("red", "#e06c75"), "green": pick("green", "#98c379"),
             "yellow": pick("bright_yellow", "#e5c07b")}
    scheme = "light" if colors.get("mode") == "light" else "dark"
    return ":root{color-scheme:%s;%s}\n" % (scheme, "".join("--%s:%s;" % kv for kv in vars_.items()))


# ----------------------------------------------------------------- print / PDF --
def print_html(issue_id, file_urls=True, tok=None):
    i = of_db.get_issue(issue_id)
    if not i:
        return None
    e = html.escape

    def media(att):
        if file_urls:
            return "file://" + urllib.parse.quote(os.path.join(i["dir"], att["path"]))
        return signed(tok, "/media/%d/%s" % (i["id"], att["path"]))

    rows = [("About", "%s: %s %s" % (of_report.SUBJECT_WORDS.get(i["subject_type"], ""), i.get("subject_name") or i.get("subject_id") or "", i.get("subject_version") or "")),
            ("Status", i["status"]), ("Reported", of_report.ts(i["created_at"]))]
    if i.get("author"):
        rows.append(("Author", i["author"]))
    if i.get("repo_url"):
        rows.append(("Project", i["repo_url"]))
    win = (i.get("context") or {}).get("activewindow") or {}
    if win.get("class"):
        rows.append(("Focused window", "%s — %s" % (win.get("class"), win.get("title") or "")))
    rows += of_report.env_rows(i)
    images = []
    order = {"annotated": 0, "markup": 1, "window": 2, "screenshot": 3}
    for a in sorted((a for a in i["attachments"] if a["kind"] in order and (a.get("mime") or "").startswith("image/")),
                    key=lambda a: (order[a["kind"]], -a["id"])):
        images.append('<figure><img src="%s" alt=""><figcaption>%s</figcaption></figure>'
                      % (e(media(a)), e(of_report.ATTACH_WORDS.get(a["kind"], a["kind"]))))
    lines, total = of_report.timeline(i, 80)
    has_replay = any(a["kind"] == "replay" for a in i["attachments"])
    doc = ["<!doctype html><html><head><meta charset='utf-8'><title>%s</title><style>" % e(i["title"]),
           "body{font:13px/1.45 system-ui,sans-serif;margin:28px;color:#111}h1{font-size:20px;margin:0 0 4px}"
           ".meta{color:#555;margin-bottom:14px}table{border-collapse:collapse;margin:8px 0 16px}"
           "td{border-top:1px solid #ddd;padding:3px 10px 3px 0;vertical-align:top}td:first-child{color:#555;white-space:nowrap}"
           "h2{font-size:15px;margin:18px 0 6px;break-after:avoid;page-break-after:avoid}.text{white-space:pre-wrap}pre{font:11px/1.35 ui-monospace,monospace;"
           "background:#f4f4f4;padding:8px;white-space:pre-wrap}figure{margin:10px 0;page-break-inside:avoid}"
           "img{max-width:100%;max-height:220mm;object-fit:contain;border:1px solid #ccc}figcaption{color:#555;font-size:11px}",
           "</style></head><body>",
           "<h1>%s</h1><div class='meta'>%s · #%d</div>" % (e(i["title"]), "Bug" if i["kind"] == "bug" else "Feature request", i["id"]),
           "<table>%s</table>" % "".join("<tr><td>%s</td><td>%s</td></tr>" % (e(k), e(str(v))) for k, v in rows),
           "<h2>What happened</h2><div class='text'>%s</div>" % e(i.get("description") or "No description.")]
    if i.get("notes"):
        doc.append("<h2>Notes</h2><div class='text'>%s</div>" % e(i["notes"]))
    if images:
        doc.append("<h2>Screenshots</h2>" + "".join(images))
    if lines:
        doc.append("<h2>Leading up to the report</h2><p>Last %d of %d events, relative to the capture. Typed text is never recorded.%s</p><pre>%s</pre>"
                   % (len(lines), total, " A screen replay is attached to the issue." if has_replay else "", e("\n".join(lines))))
    doc.append("<p class='meta'>Recorded with Omarchy Feedback.</p></body></html>")
    return "".join(doc)


def chromium_bin():
    for name in (os.environ.get("OF_CHROMIUM") or "", "chromium", "google-chrome-stable", "brave", "microsoft-edge-stable"):
        if name and shutil.which(name):
            return shutil.which(name)
    return None


def render_pdf(issue_id, out):
    exe = chromium_bin()
    if not exe:
        raise RuntimeError("Chromium is needed for PDF export")
    doc = print_html(issue_id, file_urls=True)
    if doc is None:
        raise RuntimeError("no issue %s" % issue_id)
    rt = runtime_dir()
    os.makedirs(rt, mode=0o700, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=rt, prefix="print-") as tmp:
        page = os.path.join(tmp, "issue.html")
        with open(page, "w", encoding="utf-8") as f:
            f.write(doc)
        # A private profile, so this never hands the job to the user's running browser.
        argv = [exe, "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
                "--user-data-dir=" + os.path.join(tmp, "profile"), "--allow-file-access-from-files",
                "--no-pdf-header-footer", "--print-to-pdf=" + out, "file://" + page]
        p = subprocess.run(argv, capture_output=True, text=True, timeout=90)
        if not os.path.exists(out) or os.path.getsize(out) == 0:
            raise RuntimeError("Chromium did not write the PDF: %s" % (p.stderr.strip()[-300:] or p.returncode))
    return out


def scan_in_background(issue_id):
    if os.environ.get("OF_SCAN_SYNC") == "1":
        of_secrets.scan_issue(issue_id)
        return
    try:
        subprocess.Popen(["nice", "-n", "19", sys.executable, os.path.join(HERE, "of_secrets.py"), "scan", str(int(issue_id))],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        pass


def export_dir():
    """Where the viewer's Save buttons put files: the XDG Downloads folder (created if missing)."""
    d = os.environ.get("OF_EXPORT_DIR", "")
    if not d:
        home = os.path.expanduser("~")
        try:
            d = subprocess.run(["xdg-user-dir", "DOWNLOAD"], capture_output=True, text=True, timeout=5).stdout.strip()
        except (OSError, subprocess.TimeoutExpired):
            d = ""
        # xdg-user-dir prints $HOME when no Downloads folder is configured.
        if not d or not os.path.isabs(d) or os.path.realpath(d) == os.path.realpath(home):
            d = os.path.join(home, "Downloads")
    os.makedirs(d, exist_ok=True)
    return os.path.realpath(d)


def export_name(issue, fmt):
    slug = re.sub(r"[^a-z0-9]+", "-", (issue.get("title") or "").lower()).strip("-")[:40].strip("-")
    return "feedback-%d%s.%s" % (issue["id"], "-" + slug if slug else "", fmt)


def save_export(issue_id, fmt):
    """Write the Markdown or PDF summary into export_dir(); returns where it went."""
    i = of_db.get_issue(issue_id)
    d = export_dir()
    name = export_name(i, fmt)
    out = os.path.join(d, name)
    tmp = os.path.join(d, ".%s.part" % name)
    try:
        if fmt == "md":
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(of_report.summary(issue_id, events_limit=80))
        else:
            render_pdf(issue_id, tmp)
        os.replace(tmp, out)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    return {"ok": True, "path": out, "dir": d, "name": name, "bytes": os.path.getsize(out)}


def saved_export(issue_id, path):
    """A path the page sends back is accepted only if it is this issue's export in export_dir()."""
    if not isinstance(path, str) or not os.path.isabs(path):
        return None
    real = os.path.realpath(path)
    if (os.path.dirname(real) != export_dir() or not os.path.isfile(real)
            or not re.fullmatch(r"feedback-%d(-[a-z0-9-]+)?\.(md|pdf)" % issue_id, os.path.basename(real))):
        return None
    return real


def reveal(path):
    """Show the file selected in the file manager (FileManager1 over D-Bus), else open its folder."""
    uri = "file://" + urllib.parse.quote(path)
    try:
        p = subprocess.run(["dbus-send", "--session", "--print-reply", "--dest=org.freedesktop.FileManager1",
                            "/org/freedesktop/FileManager1", "org.freedesktop.FileManager1.ShowItems",
                            "array:string:" + uri, "string:"], capture_output=True, timeout=10)
        if p.returncode == 0:
            return "file-manager"
    except (OSError, subprocess.TimeoutExpired):
        pass
    subprocess.Popen(["xdg-open", os.path.dirname(path)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
    return "folder"


# ---------------------------------------------------------------------- server --
class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "omarchy-feedback"
    sys_version = ""

    def log_message(self, fmt, *args):  # quiet; errors go to the daemon log
        if os.environ.get("OF_VIEWER_LOG"):
            sys.stderr.write("viewer: " + fmt % args + "\n")

    # -- helpers
    @property
    def origin(self):
        return "http://%s:%d" % (self.server.host, self.server.port)

    def send(self, code, body=b"", ctype="application/json", extra=None):
        if isinstance(body, str):
            body = body.encode()
        elif not isinstance(body, (bytes, bytearray)):
            body = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", CSP)
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def err(self, code, msg):
        self.send(code, {"error": msg})

    def host_ok(self):
        return self.headers.get("Host", "") == "%s:%d" % (self.server.host, self.server.port)

    def token_ok(self):
        got = self.headers.get("X-Feedback-Token", "")
        return bool(got) and hmac.compare_digest(got, self.server.token)

    def mutation_ok(self):
        return (self.headers.get("Sec-Fetch-Site") == "same-origin"
                and self.headers.get("Origin") == self.origin
                and (self.headers.get("Content-Type") or "").split(";")[0].strip() == "application/json")

    def body_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0 or n > MAX_BODY:
            raise ValueError("body too large or empty")
        data = json.loads(self.rfile.read(n).decode("utf-8"))
        if not isinstance(data, dict):
            raise ValueError("expected a JSON object")
        return data

    def route(self):
        u = urllib.parse.urlsplit(self.path)
        return u.path, urllib.parse.parse_qs(u.query)

    # -- verbs
    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        if not self.host_ok():
            return self.err(421, "wrong host")
        path, q = self.route()
        if path in STATIC:
            return self.static(STATIC[path])
        if path == "/theme.css":
            return self.send(200, theme_css(), "text/css; charset=utf-8", {"Cache-Control": "no-store"})
        if path.startswith("/media/"):
            return self.media(path, q)
        if path.startswith("/api/"):
            if not self.token_ok():
                return self.err(401, "missing or wrong token")
            return self.api_get(path, q)
        return self.err(404, "not found")

    def do_POST(self):
        self.mutate("POST")

    def do_PATCH(self):
        self.mutate("PATCH")

    def do_PUT(self):
        self.err(405, "method not allowed")

    def do_DELETE(self):
        self.err(405, "issues are deleted from the desktop, not the viewer")

    def mutate(self, verb):
        if not self.host_ok():
            return self.err(421, "wrong host")
        path, _ = self.route()
        if not path.startswith("/api/"):
            return self.err(404, "not found")
        if not self.token_ok():
            return self.err(401, "missing or wrong token")
        if not self.mutation_ok():
            return self.err(403, "cross-site request refused")
        try:
            body = self.body_json()
        except (ValueError, UnicodeDecodeError) as e:
            return self.err(400, str(e))
        m = re.fullmatch(r"/api/issues/(\d+)(/markup|/handoff|/save|/reveal|/rotated)?", path)
        if not m:
            return self.err(404, "not found")
        issue_id, sub = int(m.group(1)), m.group(2)
        if not of_db.get_issue(issue_id):
            return self.err(404, "no such issue")
        try:
            if verb == "POST" and sub == "/save":
                if body.get("format") not in ("md", "pdf"):
                    return self.err(400, "format must be md or pdf")
                try:
                    return self.send(200, save_export(issue_id, body["format"]))
                except (OSError, RuntimeError, subprocess.TimeoutExpired) as e:
                    return self.err(500, str(e))
            if verb == "POST" and sub == "/rotated":
                of_db.mark_rotated(issue_id)
                self.refresh_summary(issue_id)
                return self.send(200, self.issue_payload(issue_id))
            if verb == "POST" and sub == "/reveal":
                p = saved_export(issue_id, body.get("path"))
                if not p:
                    return self.err(404, "that export is not in the Downloads folder any more; save it again")
                return self.send(200, {"ok": True, "path": p, "shown": reveal(p)})
            if verb == "PATCH" and not sub:
                for field in ("title", "kind", "status", "notes", "description"):
                    if field in body:
                        if not isinstance(body[field], str):
                            return self.err(400, "%s must be text" % field)
                        of_db.set_field(issue_id, field, body[field], by="viewer")
                self.refresh_summary(issue_id)
                of_secrets.send_alerts(issue_id)   # anything masked in the new text: tell the user to rotate
                return self.send(200, self.issue_payload(issue_id))
            if verb == "POST" and sub == "/markup":
                return self.save_markup(issue_id, body)
            if verb == "POST" and sub == "/handoff":
                target = body.get("target")
                if target not in ("rix", "agent", "author"):
                    return self.err(400, "target must be rix, agent or author")
                p = subprocess.run([CLI, "handoff", "request", target, str(issue_id), "--json"],
                                   capture_output=True, text=True, timeout=30)
                if p.returncode != 0:
                    return self.err(500, (p.stderr.strip() or "hand-off request failed")[-300:])
                return self.send(200, json.loads(p.stdout.strip().splitlines()[-1]))
        except SystemExit as e:  # of_db validation errors
            return self.err(400, str(e))
        return self.err(405, "method not allowed")

    # -- handlers
    def static(self, name):
        path = os.path.join(WEB, name)
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError:
            return self.err(404, "not found")
        ctype = {"index.html": "text/html; charset=utf-8", "app.js": "text/javascript; charset=utf-8",
                 "sw.js": "text/javascript; charset=utf-8", "app.css": "text/css; charset=utf-8",
                 "manifest.webmanifest": "application/manifest+json", "icon.svg": "image/svg+xml",
                 "icon.png": "image/png", "icon-192.png": "image/png", "icon-512.png": "image/png"}.get(name, "application/octet-stream")
        extra = {"Cache-Control": "no-cache"}
        if name == "sw.js":
            extra["Service-Worker-Allowed"] = "/"
        self.send(200, data, ctype, extra)

    def issue_payload(self, issue_id):
        i = of_db.get_issue(issue_id)
        tok = self.server.token
        for a in i["attachments"]:
            a["url"] = signed(tok, "/media/%d/%s" % (i["id"], a["path"]))
        i.pop("dir", None)
        return i

    def api_get(self, path, q):
        if path == "/api/issues":
            status = (q.get("status") or ["open"])[0]
            return self.send(200, of_db.list_issues(status))
        if path == "/api/status":
            try:
                with open(os.path.join(runtime_dir(), "status.json")) as f:
                    st = json.load(f)
            except (OSError, ValueError):
                st = {"running": False}
            return self.send(200, {"recorder": st, "version": self.server.version})
        m = re.fullmatch(r"/api/issues/(\d+)(/events|/export\.md|/export\.pdf)?", path)
        if not m:
            return self.err(404, "not found")
        issue_id, sub = int(m.group(1)), m.group(2)
        if not of_db.get_issue(issue_id):
            return self.err(404, "no such issue")
        if not sub:
            return self.send(200, self.issue_payload(issue_id))
        if sub == "/events":
            return self.send(200, of_db.get_events(issue_id))
        if sub == "/export.md":
            return self.send(200, of_report.summary(issue_id, events_limit=80), "text/markdown; charset=utf-8",
                             {"Content-Disposition": 'attachment; filename="feedback-%d.md"' % issue_id,
                              "Cache-Control": "no-store"})
        if sub == "/export.pdf":
            out = os.path.join(of_db.issue_dir(issue_id), "feedback-%d.pdf" % issue_id)
            try:
                render_pdf(issue_id, out)
            except (RuntimeError, subprocess.TimeoutExpired) as e:
                return self.err(500, str(e))
            with open(out, "rb") as f:
                data = f.read()
            return self.send(200, data, "application/pdf",
                             {"Content-Disposition": 'attachment; filename="feedback-%d.pdf"' % issue_id,
                              "Cache-Control": "no-store"})
        return self.err(404, "not found")

    def media(self, path, q):
        exp = (q.get("exp") or ["0"])[0]
        sig = (q.get("sig") or [""])[0]
        m = re.fullmatch(r"/media/(\d+)/([A-Za-z0-9._-]+)", path)
        if not m or not exp.isdigit() or int(exp) < time.time():
            return self.err(403, "expired or malformed media link")
        if not hmac.compare_digest(sig, sign(self.server.token, path, int(exp))):
            return self.err(403, "bad media signature")
        issue_id, name = int(m.group(1)), m.group(2)
        i = of_db.get_issue(issue_id)
        if not i or name not in {a["path"] for a in i["attachments"]}:
            return self.err(404, "not found")
        full = os.path.join(i["dir"], name)
        try:
            size = os.path.getsize(full)
        except OSError:
            return self.err(404, "not found")
        ctype = mimetypes.guess_type(full)[0] or "application/octet-stream"
        start, end, code = 0, size - 1, 200
        rng = self.headers.get("Range")
        if rng:
            mm = re.fullmatch(r"bytes=(\d*)-(\d*)", rng.strip())
            if not mm or (mm.group(1) == "" and mm.group(2) == ""):
                return self.send(416, b"", ctype, {"Content-Range": "bytes */%d" % size})
            if mm.group(1) == "":
                start = max(0, size - int(mm.group(2)))
            else:
                start = int(mm.group(1))
                end = min(size - 1, int(mm.group(2))) if mm.group(2) else size - 1
            if start > end or start >= size:
                return self.send(416, b"", ctype, {"Content-Range": "bytes */%d" % size})
            code = 206
        with open(full, "rb") as f:
            f.seek(start)
            data = f.read(end - start + 1)
        extra = {"Accept-Ranges": "bytes", "Cache-Control": "private, max-age=3600"}
        if code == 206:
            extra["Content-Range"] = "bytes %d-%d/%d" % (start, end, size)
        self.send(code, data, ctype, extra)

    def save_markup(self, issue_id, body):
        shapes = body.get("shapes")
        png = body.get("png") or ""
        base = body.get("base") or ""
        if not isinstance(shapes, list) or not png.startswith("data:image/png;base64,"):
            return self.err(400, "markup needs shapes (list) and png (data URL)")
        try:
            raw = base64.b64decode(png.split(",", 1)[1], validate=True)
        except ValueError:
            return self.err(400, "png is not valid base64")
        if not raw.startswith(b"\x89PNG\r\n\x1a\n"):
            return self.err(400, "png is not a PNG")
        d = of_db.issue_dir(issue_id)
        n = 1
        while os.path.exists(os.path.join(d, "markup-%d.png" % n)):
            n += 1
        shapes, found = of_redact.redact_obj(shapes)   # text notes are masked before they are stored
        with open(os.path.join(d, "markup-%d.json" % n), "w") as f:
            json.dump({"base": base if re.fullmatch(r"[A-Za-z0-9._-]*", base) else "", "shapes": shapes}, f)
        with open(os.path.join(d, "markup-%d.png" % n), "wb") as f:
            f.write(raw)
        db = of_db.connect()
        with db:
            of_db.attach(db, issue_id, "markup", "markup-%d.png" % n, {"shapes": "markup-%d.json" % n, "base": base})
            of_db.record_secrets(db, issue_id, [dict(f, source="a note on markup-%d.png" % n) for f in found])
        self.refresh_summary(issue_id)
        # The flattened PNG carries the typed notes as pixels: OCR it (and paint over secrets) in the background.
        scan_in_background(issue_id)
        return self.send(200, self.issue_payload(issue_id))

    @staticmethod
    def refresh_summary(issue_id):
        try:
            with open(os.path.join(of_db.issue_dir(issue_id), "summary.md"), "w") as f:
                f.write(of_report.summary(issue_id))
        except OSError:
            pass


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def start(version="", host=None, port=None, write_info=True):
    """Bind (fixed address first, a random port as the fallback) and serve in a thread."""
    host = host or os.environ.get("OF_VIEWER_HOST") or DEFAULT_HOST
    port = int(port if port is not None else os.environ.get("OF_VIEWER_PORT", DEFAULT_PORT))
    fallback = False
    try:
        srv = Server((host, port), Handler)
    except OSError:
        srv = Server((host, 0), Handler)
        fallback = True
    srv.host, srv.port = host, srv.server_address[1]
    srv.token, srv.version = token(), version
    t = threading.Thread(target=srv.serve_forever, name="viewer", daemon=True)
    t.start()
    info = {"url": "http://%s:%d/" % (srv.host, srv.port), "host": srv.host, "port": srv.port, "fallback": fallback}
    if write_info:
        rt = runtime_dir()
        os.makedirs(rt, mode=0o700, exist_ok=True)
        tmp = os.path.join(rt, ".viewer.json.tmp")
        with open(tmp, "w") as f:
            json.dump(info, f)
        os.replace(tmp, os.path.join(rt, "viewer.json"))
    return srv, info


def main(argv):
    if not argv:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cmd = argv[0]
    if cmd == "serve":
        srv, info = start()
        print(json.dumps(info), flush=True)
        try:
            while True:
                time.sleep(3600)
        except KeyboardInterrupt:
            srv.shutdown()
        return 0
    if cmd == "pdf":
        try:
            print(json.dumps({"ok": True, "path": render_pdf(int(argv[1]), os.path.abspath(argv[2]))}))
            return 0
        except (RuntimeError, subprocess.TimeoutExpired, ValueError) as e:
            print(json.dumps({"ok": False, "error": str(e)}))
            return 1
    if cmd == "url":
        try:
            with open(os.path.join(runtime_dir(), "viewer.json")) as f:
                info = json.load(f)
        except (OSError, ValueError):
            info = {"url": "http://%s:%d/" % (DEFAULT_HOST, DEFAULT_PORT), "fallback": False}
        frag = "t=" + urllib.parse.quote(token())
        if len(argv) > 1 and argv[1].isdigit():
            frag += "&issue=" + argv[1]
        print(info["url"] + "#" + frag)
        return 0
    if cmd == "print-html":
        doc = print_html(int(argv[1]))
        if doc is None:
            return 1
        sys.stdout.write(doc)
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
