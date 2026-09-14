#!/usr/bin/env python3
"""Find secrets that may have been captured with an issue, hide them, and tell the user to rotate.

  of_secrets.py scan <id> [--no-notify]    redact stored text, OCR and black out images, sample the replay
  of_secrets.py scan-all [--no-notify]     every issue not yet scanned (older issues after an update)
  of_secrets.py list <id>                  JSON: the issue's findings (masked only)
  of_secrets.py notify <id>                announce findings not yet announced (one notification)
  of_secrets.py rotated <id>               mark every open finding of the issue as rotated

Text is redacted before it is stored (of_db.create / set_field); this adds what text rules
cannot see: secrets visible in the screenshot, the window crop, markup images and the screen
replay. Image regions are painted black in place. A secret seen in the replay cannot be cut
out of the video, so it is reported and the user can delete the replay.
"""
import sys

sys.dont_write_bytecode = True

import csv  # noqa: E402
import io  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import shutil  # noqa: E402
import subprocess  # noqa: E402
import tempfile  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import of_db  # noqa: E402
import of_events  # noqa: E402
import of_redact  # noqa: E402

CLI = os.path.join(os.path.dirname(HERE), "bin", "omarchy-feedback")
IMAGE_KINDS = ("screenshot", "window", "annotated", "markup")
IMAGE_WORDS = {"screenshot": "the screenshot", "window": "the window screenshot",
               "annotated": "the marked-up screenshot", "markup": "a marked-up screenshot"}
# OCR garbles text; a random-looking run from noise must not ask the user to rotate anything.
OCR_SKIP = {"possible token", "identifier", "account or ID number"}
MAX_REPLAY_FRAMES = 30


def tool(name):
    return shutil.which(name)


# ------------------------------------------------------------------ images --
def ocr_lines(png):
    """[(text, [(word, left, top, width, height), ...])] per OCR line, or None without tesseract."""
    exe = tool("tesseract")
    if not exe:
        return None
    try:
        p = subprocess.run([exe, png, "stdout", "tsv"], capture_output=True, text=True, timeout=180)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if p.returncode != 0:
        return None
    lines = {}
    for r in csv.DictReader(io.StringIO(p.stdout), delimiter="\t", quoting=csv.QUOTE_NONE):
        text = (r.get("text") or "").strip()
        if r.get("level") != "5" or not text:
            continue
        key = (r["page_num"], r["block_num"], r["par_num"], r["line_num"])
        lines.setdefault(key, []).append((text, int(r["left"]), int(r["top"]), int(r["width"]), int(r["height"])))
    return [(" ".join(w[0] for w in words), words) for words in lines.values()]


def find_in_image(png):
    """(findings, boxes) for alert-level secrets OCR can read in png; None when OCR is unavailable."""
    lines = ocr_lines(png)
    if lines is None:
        return None
    findings, boxes = [], []
    for text, words in lines:
        starts, pos = [], 0
        for w in words:
            starts.append(pos)
            pos += len(w[0]) + 1
        for s, e, label, style, alert in of_redact.scan(text):
            if not alert or label in OCR_SKIP:
                continue
            value = text[s:e]
            masked = of_redact.STARS if style == "stars" else of_redact.mask(value)
            f = {"kind": label, "masked": masked, "alert": True}
            if f not in findings:
                findings.append(f)
            hit = [w for w, st in zip(words, starts) if st < e and s < st + len(w[0])]
            if hit:
                x0 = min(w[1] for w in hit)
                y0 = min(w[2] for w in hit)
                x1 = max(w[1] + w[3] for w in hit)
                y1 = max(w[2] + w[4] for w in hit)
                boxes.append((max(0, x0 - 3), max(0, y0 - 3), x1 - x0 + 6, y1 - y0 + 6))
    return findings, boxes


def black_out(png, boxes):
    """Paint the boxes black in place (ffmpeg drawbox)."""
    if not boxes:
        return True
    exe = tool("ffmpeg")
    if not exe:
        return False
    chain = ",".join("drawbox=x=%d:y=%d:w=%d:h=%d:color=black:t=fill" % b for b in boxes)
    tmp = png + ".redacted.png"
    p = subprocess.run([exe, "-loglevel", "error", "-y", "-i", png, "-vf", chain, "-frames:v", "1", tmp],
                       capture_output=True, text=True, timeout=120)
    if p.returncode != 0 or not os.path.exists(tmp):
        if os.path.exists(tmp):
            os.unlink(tmp)
        return False
    os.replace(tmp, png)
    return True


def replay_frames(video, out_dir):
    exe, probe = tool("ffmpeg"), tool("ffprobe")
    if not exe:
        return []
    duration = 60.0
    if probe:
        try:
            duration = float(subprocess.run([probe, "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", video],
                                            capture_output=True, text=True, timeout=30).stdout.strip() or 60)
        except (OSError, ValueError, subprocess.TimeoutExpired):
            pass
    fps = min(0.5, MAX_REPLAY_FRAMES / max(duration, 1.0))
    subprocess.run([exe, "-loglevel", "error", "-i", video, "-vf", "fps=%.4f" % fps, "-frames:v", str(MAX_REPLAY_FRAMES),
                    os.path.join(out_dir, "frame-%03d.png")], capture_output=True, timeout=600)
    frames = sorted(f for f in os.listdir(out_dir) if f.startswith("frame-"))
    return [(os.path.join(out_dir, f), i / fps) for i, f in enumerate(frames)]


# ------------------------------------------------------------------- issues --
def scrub_stored_text(issue_id):
    """Redact text stored before redaction existed (older issues); returns findings with sources."""
    found = []
    db = of_db.connect()
    with db:
        r = db.execute("SELECT title, description, notes, context_json FROM issues WHERE id = ?", (issue_id,)).fetchone()
        if not r:
            return found
        updates = {}
        for field in ("title", "description", "notes"):
            clean, fs = of_redact.redact(r[field] or "")
            found += [dict(f, source=field) for f in fs]
            if clean != (r[field] or ""):
                updates[field] = clean
        try:
            ctx = json.loads(r["context_json"] or "{}")
        except ValueError:
            ctx = {}
        clean_ctx, fs = of_redact.redact_obj(ctx)
        found += [dict(f, source="title of the %s window" % ((ctx.get("activewindow") or {}).get("class") or "focused"))
                  for f in fs]
        if clean_ctx != ctx:
            updates["context_json"] = json.dumps(clean_ctx)
        for field, value in updates.items():
            db.execute("UPDATE issues SET %s = ? WHERE id = ?" % field, (value, issue_id))
        for e in db.execute("SELECT seq, json FROM events WHERE issue_id = ?", (issue_id,)).fetchall():
            try:
                ev = json.loads(e["json"])
            except ValueError:
                continue
            clean, fs = of_redact.redact_obj(ev)
            if fs:
                found += [dict(f, source="title of the %s window (event log)" % (ev.get("class") or "a")) for f in fs]
                db.execute("UPDATE events SET json = ?, label = ? WHERE issue_id = ? AND seq = ?",
                           (json.dumps(clean), of_events.describe(clean), issue_id, e["seq"]))
    d = of_db.issue_dir(issue_id)
    if os.path.isdir(d):
        found += [f for f in of_db.scrub_pending(d, _load_meta(d)) if f not in found]
        for name in os.listdir(d):
            if name.startswith("markup-") and name.endswith(".json"):
                path = os.path.join(d, name)
                try:
                    with open(path) as f:
                        obj = json.load(f)
                except (OSError, ValueError):
                    continue
                clean, fs = of_redact.redact_obj(obj)
                if fs:
                    of_db._write_json(path, clean)
                    found += [dict(f, source="a note on %s" % name.replace(".json", ".png")) for f in fs]
    return found


def _load_meta(d):
    try:
        with open(os.path.join(d, "meta.json")) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def scan_issue(issue_id, notify=True):
    issue = of_db.get_issue(issue_id)
    if not issue:
        raise SystemExit("of_secrets: no issue %s" % issue_id)
    found = scrub_stored_text(issue_id)
    d = issue["dir"]
    images = replay = 0
    ocr = "ok" if tool("tesseract") else "tesseract not installed"
    if tool("tesseract"):
        for a in issue["attachments"]:
            if a["kind"] not in IMAGE_KINDS:
                continue
            path = os.path.join(d, a["path"])
            if not os.path.isfile(path):
                continue
            res = find_in_image(path)
            if res is None:
                continue
            images += 1
            fs, boxes = res
            if boxes and not black_out(path, boxes):
                ocr = "could not paint over %s" % a["path"]
            found += [dict(f, source=IMAGE_WORDS.get(a["kind"], a["path"]) + ("" if boxes else " (not painted over)"))
                      for f in fs]
        video = next((os.path.join(d, a["path"]) for a in issue["attachments"] if a["kind"] == "replay"), None)
        if video and os.path.isfile(video):
            rt = os.environ.get("OF_RUNTIME") or os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "omarchy-feedback")
            os.makedirs(rt, mode=0o700, exist_ok=True)
            with tempfile.TemporaryDirectory(dir=rt, prefix="scan-") as tmp:
                for frame, at in replay_frames(video, tmp):
                    res = find_in_image(frame)
                    replay += 1
                    if res:
                        found += [dict(f, source="the screen replay (around %d:%02d)" % (at // 60, at % 60)) for f in res[0]]
    db = of_db.connect()
    with db:
        new = of_db.record_secrets(db, issue_id, _dedupe(found))
        db.execute("INSERT OR REPLACE INTO scans(issue_id, scanned_at, images, replay, ocr) VALUES (?,?,?,?,?)",
                   (issue_id, of_db.now_ms(), images, replay, ocr))
    if notify:
        send_alerts(issue_id)
    return {"id": issue_id, "new": new, "open": of_db.get_secrets(issue_id, open_only=True), "images": images,
            "replayFrames": replay, "ocr": ocr}


def _dedupe(found):
    out = []
    for f in found:
        f = {k: f[k] for k in ("kind", "masked", "alert", "source")}
        if f not in out:
            out.append(f)
    return out


def send_alerts(issue_id):
    """One notification for findings not yet announced; marks them notified."""
    db = of_db.connect()
    rows = [of_db.row(r) for r in db.execute(
        "SELECT * FROM secrets WHERE issue_id = ? AND notified_at IS NULL AND rotated_at IS NULL ORDER BY id", (issue_id,))]
    if not rows:
        return 0
    if len(rows) == 1:
        s = rows[0]
        head = "Possible %s captured in feedback #%d" % (s["kind"], issue_id)
        body = "%s in %s may be compromised. Rotate it as soon as possible, then mark it rotated." % (s["masked"], s["source"])
    else:
        head = "%d possible secrets captured in feedback #%d" % (len(rows), issue_id)
        body = "; ".join("%s %s (%s)" % (s["kind"], s["masked"], s["source"]) for s in rows[:4])
        body += ". They may be compromised: rotate them as soon as possible, then mark them rotated."
    exe = tool("omarchy-notification-send")
    if exe:
        subprocess.run([exe, "--app-name", "Feedback", "-g", "󰌾", "-u", "critical", head, body,
                        "--exec", CLI, "open", str(issue_id)], capture_output=True, timeout=10)
    else:
        print("notify: %s: %s" % (head, body), file=sys.stderr)
    with db:
        db.executemany("UPDATE secrets SET notified_at = ? WHERE id = ?", [(of_db.now_ms(), s["id"]) for s in rows])
    return len(rows)


def scan_all(notify=True):
    db = of_db.connect()
    ids = [r[0] for r in db.execute("SELECT id FROM issues WHERE id NOT IN (SELECT issue_id FROM scans) ORDER BY id")]
    return [scan_issue(i, notify) for i in ids]


def main(argv):
    notify = "--no-notify" not in argv
    args = [a for a in argv if a != "--no-notify"]
    if args[:1] == ["scan"] and len(args) == 2 and args[1].isdigit():
        print(json.dumps(scan_issue(int(args[1]), notify)))
    elif args[:1] == ["scan-all"]:
        print(json.dumps(scan_all(notify)))
    elif args[:1] == ["list"] and len(args) == 2 and args[1].isdigit():
        print(json.dumps(of_db.get_secrets(int(args[1]))))
    elif args[:1] == ["notify"] and len(args) == 2 and args[1].isdigit():
        print(json.dumps({"notified": send_alerts(int(args[1]))}))
    elif args[:1] == ["rotated"] and len(args) == 2 and args[1].isdigit():
        print(json.dumps({"rotated": of_db.mark_rotated(int(args[1]))}))
    else:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
