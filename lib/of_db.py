#!/usr/bin/env python3
"""The local issue database for omarchy-feedback (SQLite, WAL).

  of_db.py init
  of_db.py create <pending-dir>            meta.json + captured files -> new issue; prints {"id": N, "dir": ...}
  of_db.py list [--status open|all|<status>]   JSON array for the panel and the viewer
  of_db.py get <id>                        JSON issue with attachments, handoffs, events count
  of_db.py events <id>                     JSON array of the issue's events
  of_db.py set <id> <field> <value>        status | notes | title | description | kind  (status changes are logged)
  of_db.py delete <id>
  of_db.py attach <id> <kind> <path> [meta-json]
  of_db.py handoff-add <id> <target> <status> <argv-json> <workdir>   prints handoff id
  of_db.py handoff-set <handoff-id> <status> [result-ref]
  of_db.py handoff-get <handoff-id>

Issue folders live in $OF_STATE/issues/<id>/. Paths stored in attachments are
relative to that folder.
"""
import sys

sys.dont_write_bytecode = True

import json  # noqa: E402
import mimetypes  # noqa: E402
import os  # noqa: E402
import shutil  # noqa: E402
import sqlite3  # noqa: E402
import time  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import of_events  # noqa: E402

SCHEMA_VERSION = 1
STATUSES = ("new", "triaged", "sent-to-rix", "sent-to-agent", "sent-to-author", "fixed", "closed")
OPEN_STATUSES = ("new", "triaged", "sent-to-rix", "sent-to-agent", "sent-to-author")
KINDS = ("bug", "feature")
SUBJECT_TYPES = ("plugin", "app", "omarchy", "unknown")
ATTACH_KINDS = ("screenshot", "window", "annotated", "markup", "replay", "events", "summary", "feedback", "pdf", "other")
TARGETS = ("rix", "agent", "author")
HANDOFF_STATUSES = ("pending-confirm", "launched", "failed", "done", "declined")
# Files a capture may leave in the pending folder, and what they are.
CAPTURE_FILES = {"shot.png": "screenshot", "window.png": "window", "annotated.png": "annotated",
                 "replay.mp4": "replay", "events.jsonl": "events"}

SCHEMA = f"""
CREATE TABLE IF NOT EXISTS issues(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
  title TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN {KINDS}),
  subject_type TEXT NOT NULL CHECK(subject_type IN {SUBJECT_TYPES}),
  subject_id TEXT, subject_name TEXT, subject_version TEXT, repo_url TEXT, author TEXT,
  description TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'new' CHECK(status IN {STATUSES}),
  notes TEXT NOT NULL DEFAULT '', source TEXT, capture_t_ms INTEGER, monitor TEXT, context_json TEXT);
CREATE TABLE IF NOT EXISTS attachments(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  issue_id INTEGER NOT NULL REFERENCES issues(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK(kind IN {ATTACH_KINDS}), path TEXT NOT NULL, mime TEXT, bytes INTEGER,
  meta_json TEXT, created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS events(
  issue_id INTEGER NOT NULL REFERENCES issues(id) ON DELETE CASCADE,
  seq INTEGER NOT NULL, t_ms INTEGER, type TEXT, label TEXT, json TEXT,
  PRIMARY KEY(issue_id, seq));
CREATE TABLE IF NOT EXISTS handoffs(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  issue_id INTEGER NOT NULL REFERENCES issues(id) ON DELETE CASCADE,
  target TEXT NOT NULL CHECK(target IN {TARGETS}), argv_json TEXT, workdir TEXT,
  status TEXT NOT NULL CHECK(status IN {HANDOFF_STATUSES}), result_ref TEXT,
  created_at INTEGER NOT NULL, confirmed_at INTEGER);
CREATE TABLE IF NOT EXISTS status_log(
  issue_id INTEGER NOT NULL REFERENCES issues(id) ON DELETE CASCADE,
  at INTEGER NOT NULL, from_status TEXT, to_status TEXT, by TEXT);
CREATE INDEX IF NOT EXISTS issues_status ON issues(status, updated_at);
CREATE TRIGGER IF NOT EXISTS issues_touch AFTER UPDATE ON issues
  WHEN NEW.updated_at = OLD.updated_at
  BEGIN UPDATE issues SET updated_at = CAST(strftime('%s','now') AS INTEGER) * 1000 WHERE id = NEW.id; END;
"""


def now_ms():
    return int(time.time() * 1000)


def state_dir():
    return os.environ.get("OF_STATE") or os.path.join(
        os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state"), "omarchy-feedback")


def issues_dir():
    return os.path.join(state_dir(), "issues")


def issue_dir(issue_id):
    return os.path.join(issues_dir(), str(int(issue_id)))


class _Connection(sqlite3.Connection):
    """Closes itself when the last reference goes (end of the function using it).

    The viewer runs inside the long-lived daemon, so connections must not linger.
    """

    def __del__(self):
        try:
            self.close()
        except Exception:
            pass


def connect():
    d = state_dir()
    os.makedirs(d, mode=0o700, exist_ok=True)
    db = sqlite3.connect(os.path.join(d, "feedback.db"), timeout=10, factory=_Connection)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys = ON")
    db.execute("PRAGMA journal_mode = WAL")
    if db.execute("PRAGMA user_version").fetchone()[0] < SCHEMA_VERSION:
        db.executescript(SCHEMA)
        db.execute("PRAGMA user_version = %d" % SCHEMA_VERSION)
        db.commit()
    return db


def row(r):
    return dict(r) if r is not None else None


def attach(db, issue_id, kind, relpath, meta=None):
    full = os.path.join(issue_dir(issue_id), relpath)
    size = os.path.getsize(full) if os.path.exists(full) else None
    mime = mimetypes.guess_type(full)[0] or ("application/x-ndjson" if full.endswith(".jsonl") else None)
    cur = db.execute("INSERT INTO attachments(issue_id, kind, path, mime, bytes, meta_json, created_at) "
                     "VALUES (?,?,?,?,?,?,?)",
                     (issue_id, kind, relpath, mime, size, json.dumps(meta) if meta is not None else None, now_ms()))
    return cur.lastrowid


def create(pending):
    pending = os.path.abspath(pending)
    root = os.path.abspath(issues_dir())
    if os.path.dirname(pending) != root or not os.path.basename(pending).startswith(".pending-"):
        raise SystemExit("of_db: pending folder must be %s/.pending-*" % root)
    with open(os.path.join(pending, "meta.json")) as f:
        meta = json.load(f)
    title = (meta.get("title") or "").strip()
    if not title:
        raise SystemExit("of_db: a title is required")
    kind = meta.get("kind") if meta.get("kind") in KINDS else "bug"
    subj = meta.get("subject") or {}
    stype = subj.get("type") if subj.get("type") in SUBJECT_TYPES else "unknown"
    t = now_ms()
    db = connect()
    with db:
        cur = db.execute(
            "INSERT INTO issues(created_at, updated_at, title, kind, subject_type, subject_id, subject_name, "
            "subject_version, repo_url, author, description, status, source, capture_t_ms, monitor, context_json) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?,'new',?,?,?,?)",
            (t, t, title[:300], kind, stype, subj.get("id"), subj.get("name"), subj.get("version"),
             subj.get("repo"), subj.get("author"), (meta.get("description") or "")[:20000],
             meta.get("source"), meta.get("captureMs"), meta.get("monitor"), json.dumps(meta.get("context") or {})))
        issue_id = cur.lastrowid
        db.execute("INSERT INTO status_log(issue_id, at, from_status, to_status, by) VALUES (?,?,?,?,?)",
                   (issue_id, t, None, "new", meta.get("source") or "capture"))
        dest = issue_dir(issue_id)
        os.rename(pending, dest)
        for name, akind in CAPTURE_FILES.items():
            if os.path.exists(os.path.join(dest, name)) and os.path.getsize(os.path.join(dest, name)) > 0:
                extra = None
                if akind == "replay" and os.path.exists(os.path.join(dest, "replay.mp4.ts")):
                    extra = read_first_frame_ts(os.path.join(dest, "replay.mp4.ts"))
                attach(db, issue_id, akind, name, extra)
        evs = of_events.read_events(os.path.join(dest, "events.jsonl"))
        db.executemany("INSERT INTO events(issue_id, seq, t_ms, type, label, json) VALUES (?,?,?,?,?,?)",
                       [(issue_id, i, e.get("t"), e.get("type"), of_events.describe(e), json.dumps(e))
                        for i, e in enumerate(evs)])
    return {"id": issue_id, "dir": dest, "events": len(evs)}


def read_first_frame_ts(path):
    """gpu-screen-recorder -write-first-frame-ts: a header line, then 'monotonic_us realtime_us'."""
    try:
        with open(path) as f:
            for line in f:
                parts = line.split()
                if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
                    return {"firstFrameMonoMs": int(parts[0]) // 1000, "firstFrameMs": int(parts[1]) // 1000}
    except OSError:
        pass
    return None


def list_issues(status="open"):
    db = connect()
    q = ("SELECT i.*, (SELECT COUNT(*) FROM events e WHERE e.issue_id = i.id) AS event_count, "
         "(SELECT GROUP_CONCAT(kind) FROM attachments a WHERE a.issue_id = i.id) AS attachment_kinds, "
         "(SELECT COUNT(*) FROM handoffs h WHERE h.issue_id = i.id AND h.status = 'pending-confirm') AS pending_handoffs "
         "FROM issues i")
    args = ()
    if status == "open":
        q += " WHERE i.status IN (%s)" % ",".join("?" * len(OPEN_STATUSES))
        args = OPEN_STATUSES
    elif status in STATUSES:
        q += " WHERE i.status = ?"
        args = (status,)
    q += " ORDER BY i.updated_at DESC, i.id DESC"
    out = []
    for r in db.execute(q, args):
        d = row(r)
        d["attachment_kinds"] = sorted(set((d.get("attachment_kinds") or "").split(","))) if d.get("attachment_kinds") else []
        d.pop("context_json", None)
        out.append(d)
    return out


def get_issue(issue_id):
    db = connect()
    r = row(db.execute("SELECT * FROM issues WHERE id = ?", (int(issue_id),)).fetchone())
    if not r:
        return None
    try:
        r["context"] = json.loads(r.pop("context_json") or "{}")
    except ValueError:
        r["context"] = {}
    r["attachments"] = []
    for a in db.execute("SELECT * FROM attachments WHERE issue_id = ? ORDER BY id", (r["id"],)):
        a = row(a)
        a["meta"] = json.loads(a.pop("meta_json") or "null")
        r["attachments"].append(a)
    r["handoffs"] = [row(h) for h in db.execute("SELECT * FROM handoffs WHERE issue_id = ? ORDER BY id", (r["id"],))]
    r["status_log"] = [row(s) for s in db.execute("SELECT * FROM status_log WHERE issue_id = ? ORDER BY at", (r["id"],))]
    r["event_count"] = db.execute("SELECT COUNT(*) FROM events WHERE issue_id = ?", (r["id"],)).fetchone()[0]
    r["dir"] = issue_dir(r["id"])
    return r


def get_events(issue_id):
    db = connect()
    return [dict(seq=r["seq"], t=r["t_ms"], type=r["type"], label=r["label"], **{"data": json.loads(r["json"])})
            for r in db.execute("SELECT * FROM events WHERE issue_id = ? ORDER BY seq", (int(issue_id),))]


EDITABLE = ("status", "notes", "title", "description", "kind")


def set_field(issue_id, field, value, by="cli"):
    if field not in EDITABLE:
        raise SystemExit("of_db: field must be one of %s" % ", ".join(EDITABLE))
    if field == "status" and value not in STATUSES:
        raise SystemExit("of_db: status must be one of %s" % ", ".join(STATUSES))
    if field == "kind" and value not in KINDS:
        raise SystemExit("of_db: kind must be bug or feature")
    if field == "title" and not value.strip():
        raise SystemExit("of_db: a title is required")
    db = connect()
    with db:
        cur = db.execute("SELECT status FROM issues WHERE id = ?", (int(issue_id),)).fetchone()
        if not cur:
            raise SystemExit("of_db: no issue %s" % issue_id)
        db.execute("UPDATE issues SET %s = ?, updated_at = ? WHERE id = ?" % field,
                   (value[:20000], now_ms(), int(issue_id)))
        if field == "status" and cur["status"] != value:
            db.execute("INSERT INTO status_log(issue_id, at, from_status, to_status, by) VALUES (?,?,?,?,?)",
                       (int(issue_id), now_ms(), cur["status"], value, by))
    return get_issue(issue_id)


def delete_issue(issue_id):
    db = connect()
    with db:
        n = db.execute("DELETE FROM issues WHERE id = ?", (int(issue_id),)).rowcount
    d = issue_dir(issue_id)
    if n and os.path.isdir(d):
        shutil.rmtree(d)
    return n


def handoff_add(issue_id, target, status, argv_json, workdir):
    if target not in TARGETS or status not in HANDOFF_STATUSES:
        raise SystemExit("of_db: bad handoff target/status")
    db = connect()
    with db:
        cur = db.execute("INSERT INTO handoffs(issue_id, target, argv_json, workdir, status, created_at) "
                         "VALUES (?,?,?,?,?,?)", (int(issue_id), target, argv_json, workdir, status, now_ms()))
    return cur.lastrowid


def handoff_set(handoff_id, status, result_ref=None):
    if status not in HANDOFF_STATUSES:
        raise SystemExit("of_db: bad handoff status")
    db = connect()
    with db:
        db.execute("UPDATE handoffs SET status = ?, result_ref = COALESCE(?, result_ref), "
                   "confirmed_at = CASE WHEN ? IN ('launched','failed','declined') THEN ? ELSE confirmed_at END "
                   "WHERE id = ?", (status, result_ref, status, now_ms(), int(handoff_id)))
    return handoff_get(handoff_id)


def handoff_get(handoff_id):
    db = connect()
    return row(db.execute("SELECT * FROM handoffs WHERE id = ?", (int(handoff_id),)).fetchone())


def main(argv):
    if not argv:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cmd, args = argv[0], argv[1:]
    out = None
    if cmd == "init":
        connect()
        out = {"ok": True}
    elif cmd == "create":
        out = create(args[0])
    elif cmd == "list":
        status = "open"
        if len(args) >= 2 and args[0] == "--status":
            status = args[1]
        out = list_issues(status)
    elif cmd == "get":
        out = get_issue(args[0])
        if out is None:
            print("of_db: no issue %s" % args[0], file=sys.stderr)
            return 1
    elif cmd == "events":
        out = get_events(args[0])
    elif cmd == "set":
        out = set_field(args[0], args[1], args[2], by=os.environ.get("OF_BY", "cli"))
    elif cmd == "delete":
        out = {"deleted": delete_issue(args[0])}
    elif cmd == "attach":
        db = connect()
        with db:
            out = {"id": attach(db, int(args[0]), args[1], args[2], json.loads(args[3]) if len(args) > 3 else None)}
    elif cmd == "handoff-add":
        out = {"id": handoff_add(*args[:5])}
    elif cmd == "handoff-set":
        out = handoff_set(args[0], args[1], args[2] if len(args) > 2 else None)
    elif cmd == "handoff-get":
        out = handoff_get(args[0])
    else:
        print("of_db: unknown command %r" % cmd, file=sys.stderr)
        return 2
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
