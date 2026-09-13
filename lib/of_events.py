"""Rolling event log and Hyprland socket helpers for omarchy-feedback.

The log lives on tmpfs ($XDG_RUNTIME_DIR/omarchy-feedback/seg), one JSONL file
per wall-clock minute, 0600 in a 0700 directory. Only the last KEEP_MINUTES
files are kept, so nothing older survives and nothing survives a reboot.
A capture copies the last N minutes into the issue folder.
"""
import json
import os
import socket
import time

KEEP_MINUTES = 12

# socket2 event name -> timeline type. Anything else is ignored.
HYPR_TYPES = {
    "activewindow": "window", "openwindow": "window", "closewindow": "window",
    "fullscreen": "window", "changefloatingmode": "window",
    "workspace": "workspace", "focusedmon": "monitor", "monitoradded": "monitor", "monitorremoved": "monitor",
    "openlayer": "layer", "closelayer": "layer", "submap": "submap", "activelayout": "keyboard",
    "configreloaded": "config", "screencast": "screencast",
}
# Events after which the pointer position is worth recording.
CURSOR_AFTER = {"activewindow", "openlayer", "closelayer"}


def now_ms():
    return int(time.time() * 1000)


def mono_ms():
    return int(time.monotonic() * 1000)


def hypr_dir():
    d = os.environ.get("OF_HYPR_DIR")
    if d:
        return d
    return os.path.join(os.environ.get("XDG_RUNTIME_DIR", ""), "hypr", os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", ""))


def hypr_request(cmd, timeout=1.0):
    """One request on Hyprland's command socket (.socket.sock). Returns text or None."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(os.path.join(hypr_dir(), ".socket.sock"))
        s.sendall(cmd.encode())
        chunks = []
        while True:
            data = s.recv(65536)
            if not data:
                break
            chunks.append(data)
        return b"".join(chunks).decode("utf-8", "replace")
    except OSError:
        return None
    finally:
        s.close()


def hypr_json(cmd, default=None):
    text = hypr_request("j/" + cmd)
    if text is None:
        return default
    try:
        return json.loads(text)
    except ValueError:
        return default


def session_locked(monitors):
    """Same rule as omarchy-hyprland-session-locked: LOCK in any monitor's solitaryBlockedBy."""
    if not isinstance(monitors, list):
        return False
    return any("LOCK" in (m.get("solitaryBlockedBy") or []) for m in monitors if isinstance(m, dict))


def parse_hypr_line(raw, t=None, mono=None):
    """'activewindow>>class,title' -> timeline event dict, or None when not logged."""
    name, sep, data = raw.partition(">>")
    if not sep or name not in HYPR_TYPES:
        return None
    ev = {"t": t if t is not None else now_ms(), "mono": mono if mono is not None else mono_ms(),
          "type": HYPR_TYPES[name], "event": name}
    if name == "activewindow":
        cls, _, title = data.partition(",")
        ev.update({"class": cls, "title": title[:200]})
    elif name in ("openwindow",):
        parts = data.split(",", 3)
        if len(parts) == 4:
            ev.update({"address": parts[0], "workspace": parts[1], "class": parts[2], "title": parts[3][:200]})
        else:
            ev["data"] = data[:200]
    elif name in ("closewindow",):
        ev["address"] = data
    elif name == "windowtitle":
        ev["address"] = data
    elif name in ("openlayer", "closelayer"):
        ev["namespace"] = data
    elif name in ("workspace",):
        ev["workspace"] = data
    elif name in ("focusedmon",):
        mon, _, ws = data.partition(",")
        ev.update({"monitor": mon, "workspace": ws})
    elif name == "submap":
        ev["name"] = data
    else:
        ev["data"] = data[:200]
    return ev


class SegmentLog:
    def __init__(self, directory, keep_minutes=KEEP_MINUTES):
        self.dir = directory
        self.keep = keep_minutes
        self.cur_min = None
        self.f = None
        os.makedirs(self.dir, mode=0o700, exist_ok=True)
        os.chmod(self.dir, 0o700)

    def _open(self, minute):
        if self.f:
            self.f.close()
        path = os.path.join(self.dir, "%d.jsonl" % minute)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        self.f = os.fdopen(fd, "a", buffering=1, encoding="utf-8")
        self.cur_min = minute
        self.prune(minute)

    def prune(self, minute):
        for name in os.listdir(self.dir):
            if not name.endswith(".jsonl"):
                continue
            try:
                m = int(name[:-6])
            except ValueError:
                continue
            if m <= minute - self.keep:
                try:
                    os.remove(os.path.join(self.dir, name))
                except OSError:
                    pass

    def write(self, ev):
        ev.setdefault("t", now_ms())
        ev.setdefault("mono", mono_ms())
        minute = ev["t"] // 60000
        if minute != self.cur_min:
            self._open(minute)
        self.f.write(json.dumps(ev, ensure_ascii=False, separators=(",", ":")) + "\n")

    def close(self):
        if self.f:
            self.f.close()
            self.f = None


def snapshot(seg_dir, dest, minutes, now=None):
    """Copy events from the last `minutes` into dest (a file path). Returns the count."""
    now = now if now is not None else now_ms()
    since = now - minutes * 60000
    first_min = since // 60000
    files = []
    try:
        for name in os.listdir(seg_dir):
            if name.endswith(".jsonl"):
                try:
                    m = int(name[:-6])
                except ValueError:
                    continue
                if m >= first_min:
                    files.append((m, os.path.join(seg_dir, name)))
    except OSError:
        pass
    count = 0
    os.makedirs(os.path.dirname(os.path.abspath(dest)), exist_ok=True)
    tmp = dest + ".tmp"
    with open(tmp, "w", encoding="utf-8") as out:
        for _, path in sorted(files):
            try:
                with open(path, encoding="utf-8") as f:
                    data = f.read()
            except OSError:
                continue
            # A line still being written has no newline yet: skip it.
            lines = data.split("\n")
            if not data.endswith("\n"):
                lines = lines[:-1]
            for line in lines:
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except ValueError:
                    continue
                if since <= ev.get("t", 0) <= now:
                    out.write(line + "\n")
                    count += 1
    os.replace(tmp, dest)
    return count


def read_events(path):
    evs = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                try:
                    evs.append(json.loads(line))
                except ValueError:
                    pass
    except OSError:
        pass
    return evs


def describe(ev):
    """One human line for an event (timelines, FEEDBACK.md, the viewer's fallback)."""
    t = ev.get("type")
    if t == "key":
        return "key " + (ev.get("combo") or "?") + (" (typed text hidden)" if ev.get("redacted") else "")
    if t == "window":
        e = ev.get("event")
        if e == "activewindow" and ev.get("retitle"):
            return "title %s — %s" % (ev.get("class") or "", ev.get("title") or "")
        if e == "activewindow":
            return "focus %s — %s" % (ev.get("class") or "(desktop)", ev.get("title") or "")
        if e == "openwindow":
            return "open window %s — %s" % (ev.get("class", ""), ev.get("title", ""))
        if e == "closewindow":
            return "close window %s" % ev.get("address", "")
        return "%s %s" % (e, ev.get("data", ev.get("address", "")))
    if t == "layer":
        return "%s %s" % ("show" if ev.get("event") == "openlayer" else "hide", ev.get("namespace", ""))
    if t == "workspace":
        return "workspace %s" % ev.get("workspace", "")
    if t == "monitor":
        return "monitor %s %s" % (ev.get("monitor", ev.get("data", "")), ev.get("workspace", ""))
    if t == "submap":
        return "submap %s" % (ev.get("name") or "(default)")
    if t == "cursor":
        return "pointer at %s,%s" % (ev.get("x"), ev.get("y"))
    if t == "lock":
        return "screen locked, key log paused" if ev.get("locked") else "screen unlocked, key log resumed"
    if t == "mark":
        return "── report captured ──"
    if t == "screencast":
        state, _, owner = (ev.get("data") or "").partition(",")
        return "screen capture %s (%s)" % ("started" if state == "1" else "stopped", owner or "?")
    if t == "daemon":
        return "recorder %s" % ev.get("event", "")
    return "%s %s" % (t, ev.get("event", ev.get("data", "")))
