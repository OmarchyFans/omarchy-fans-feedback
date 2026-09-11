#!/usr/bin/env python3
"""Troubleshooting key and desktop-event logger for omarchy-beta-feedback.

  keylog.py run --bundle DIR --runtime DIR [--cli PATH] [--all-keys] [--show-keys] [--max SECONDS]
  keylog.py render --bundle DIR
  keylog.py lua arm --raw PATH [--all-keys] [--paused] | lua disarm

Keys come from Hyprland's own Lua event `input.keyboard.key`, registered at
runtime with `hyprctl eval`: no root, no /dev/input, nothing added to the
user's config. The Lua side writes bare "K <code> <state> <timeMs>" lines to a
0600 file in XDG_RUNTIME_DIR. Letters, digits, punctuation and space are
written as "?" unless Ctrl, Alt or Super is held or --all-keys was chosen, so
typed text never reaches the disk.

This process stamps each line as it arrives (Hyprland's timeMs is 0 for
virtual keyboards), adds desktop events from Hyprland's event socket, pauses
the listener while the Omarchy lock screen is up, re-arms it after a config
reload, and keeps overlay.json up to date for the bar widget's on-screen key
display.
"""
import argparse
import json
import os
import queue
import re
import shlex
import signal
import socket
import subprocess
import sys
import threading
import time

# XKB keycodes (evdev + 8).
MOD_NAMES = {37: "Ctrl", 105: "Ctrl", 50: "Shift", 62: "Shift", 64: "Alt", 108: "AltGr", 133: "Super", 134: "Super"}
MOD_ORDER = ["Super", "Ctrl", "Alt", "AltGr", "Shift"]
MOD_BITS = {"Shift": 1, "Ctrl": 4, "Alt": 8, "Super": 64}
# Keys that never type text: Esc, Backspace, Tab, Enter, modifiers, CapsLock,
# F1-F12, NumLock, ScrollLock, KP Enter, Print, navigation, Insert/Delete,
# volume/power, Pause, Menu. Everything >= 191 (F13 up, media, vendor) too.
NON_TEXT = (9, 22, 23, 36, 37, 50, 62, 64, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 95, 96,
            104, 105, 107, 108, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 121, 122, 123, 124,
            127, 133, 134, 135)
# Holding one of these makes the next key a shortcut, not text (AltGr types text).
REVEAL = (37, 105, 64, 133, 134)

HYPR_EVENTS = {"activewindow", "workspace", "focusedmon", "submap", "openlayer", "closelayer", "configreloaded",
               "fullscreen", "activelayout", "openwindow", "closewindow", "changefloatingmode", "screencast"}

HEADER = "/usr/include/linux/input-event-codes.h"
FALLBACK = {1: "ESC", 14: "BACKSPACE", 15: "TAB", 28: "ENTER", 29: "LEFTCTRL", 42: "LEFTSHIFT", 54: "RIGHTSHIFT",
            56: "LEFTALT", 57: "SPACE", 97: "RIGHTCTRL", 100: "RIGHTALT", 102: "HOME", 103: "UP", 104: "PAGEUP",
            105: "LEFT", 106: "RIGHT", 107: "END", 108: "DOWN", 109: "PAGEDOWN", 110: "INSERT", 111: "DELETE",
            125: "LEFTMETA", 126: "RIGHTMETA"}
FRIENDLY = {"LEFTCTRL": "Ctrl", "RIGHTCTRL": "Ctrl", "LEFTSHIFT": "Shift", "RIGHTSHIFT": "Shift", "LEFTALT": "Alt",
            "RIGHTALT": "AltGr", "LEFTMETA": "Super", "RIGHTMETA": "Super", "ESC": "Esc", "ENTER": "Enter",
            "KPENTER": "KP Enter", "BACKSPACE": "Backspace", "SPACE": "Space", "TAB": "Tab", "SYSRQ": "Print",
            "PAGEUP": "PgUp", "PAGEDOWN": "PgDn", "CAPSLOCK": "CapsLock", "COMPOSE": "Menu",
            "VOLUMEUP": "VolUp", "VOLUMEDOWN": "VolDown"}
# evdev name -> the names Hyprland binds use for the same key.
BIND_ALIASES = {"ENTER": ["RETURN"], "ESC": ["ESCAPE"], "SYSRQ": ["PRINT"], "PAGEUP": ["PRIOR", "PAGE_UP"],
                "PAGEDOWN": ["NEXT", "PAGE_DOWN"], "KPENTER": ["KP_ENTER"], "COMPOSE": ["MENU"],
                "MUTE": ["XF86AUDIOMUTE"], "VOLUMEUP": ["XF86AUDIORAISEVOLUME"],
                "VOLUMEDOWN": ["XF86AUDIOLOWERVOLUME"]}
VIDEO_TRIM_MS = 100  # omarchy-capture-screenrecording cuts the first 0.1 s when it stops


def now_ms():
    return int(time.time() * 1000)


def mono_ms():
    return int(time.monotonic() * 1000)


# ---------------------------------------------------------------- key names --
_names = None


def evdev_names():
    global _names
    if _names is None:
        _names = dict(FALLBACK)
        try:
            with open(HEADER) as f:
                seen = set()
                for m in re.finditer(r"^#define\s+KEY_(\w+)\s+(0x[0-9a-fA-F]+|\d+)\b", f.read(), re.M):
                    code = int(m.group(2), 0)
                    if code not in seen:
                        _names[code] = m.group(1)
                        seen.add(code)
        except OSError:
            pass
    return _names


def raw_name(code):
    return evdev_names().get(code - 8, "CODE%d" % code)


def key_label(code):
    if code is None:
        return "•"
    n = raw_name(code)
    return FRIENDLY.get(n, n if len(n) <= 2 else n.title())


def mods_label(mods):
    return "+".join(m for m in MOD_ORDER if m in mods)


def combo(mods, code):
    return "+".join([m for m in MOD_ORDER if m in mods] + [key_label(code)])


# ---------------------------------------------------------------------- lua --
def lua_path(path):
    if not re.fullmatch(r"[A-Za-z0-9_./@+-]+", path):
        raise SystemExit("keylog: refusing a path Lua cannot take verbatim: %r" % path)
    return '"%s"' % path


def lua_arm(raw, all_keys=False, paused=False):
    """Idempotent: a live listener only gets its pause flag updated."""
    shown = ", ".join("[%d]=true" % c for c in NON_TEXT)
    reveal = ", ".join("[%d]=true" % c for c in REVEAL)
    return f"""local paused, all = {str(paused).lower()}, {str(all_keys).lower()}
local r = _G.bfrec
if r and r.k and r.k:is_active() then r.paused = paused return end
if r and r.f then pcall(function() r.f:close() end) end
r = {{ paused = paused, all = all, held = {{}} }}
r.f = io.open({lua_path(raw)}, "a")
if not r.f then return end
local shown = {{ {shown} }}
local reveal = {{ {reveal} }}
r.k = hl.on("input.keyboard.key", function(c, t, s)
  if type(c) ~= "number" then return end
  if reveal[c] then if s == 0 then r.held[c] = nil else r.held[c] = true end end
  if r.paused then return end
  local out = c
  if not (r.all or shown[c] or c >= 191 or next(r.held) ~= nil) then out = "?" end
  r.f:write("K ", out, " ", tostring(s), " ", tostring(t), "\\n")
  r.f:flush()
end)
r.s = hl.on("keybinds.submap", function(name)
  if r.paused then return end
  r.f:write("S ", tostring(name), "\\n")
  r.f:flush()
end)
_G.bfrec = r
"""


LUA_DISARM = """local r = _G.bfrec
if r then
  if r.k then pcall(function() r.k:remove() end) end
  if r.s then pcall(function() r.s:remove() end) end
  if r.f then pcall(function() r.f:close() end) end
  _G.bfrec = nil
end
"""


# ----------------------------------------------------------------- recorder --
class Recorder:
    def __init__(self, a):
        self.bundle, self.rt, self.cli = a.bundle, a.runtime, a.cli
        self.all_keys, self.show_keys, self.max_s, self.monitor = a.all_keys, a.show_keys, a.max, a.monitor
        self.raw = os.path.join(self.rt, "keys.raw")
        self.overlay = os.path.join(self.rt, "overlay.json")
        self.hyprctl = os.environ.get("BF_HYPRCTL", "hyprctl")
        self.lock_cmd = shlex.split(os.environ.get("BF_LOCK_CMD", "omarchy-shell lock isLocked"))
        self.q = queue.Queue()
        self.stop = threading.Event()
        self.rearm = threading.Event()
        self.paused = False
        self.held = {}   # modifier keycode -> name
        self.lone = {}   # modifier keycode -> no other key pressed since it went down
        self.items = []
        self.dirty = True
        self.last_overlay = 0
        self.started = now_ms()
        self.autostopped = False
        self.errors = set()
        self.out = None

    # -- plumbing
    def emit(self, ev):
        ev.setdefault("time", now_ms())
        ev.setdefault("mono", mono_ms())
        self.out.write(json.dumps(ev, ensure_ascii=False) + "\n")

    def hypr(self, chunk):
        try:
            p = subprocess.run([self.hyprctl, "eval", chunk], capture_output=True, text=True, timeout=3)
            msg = (p.stdout + p.stderr).strip()
            bad = p.returncode != 0 or msg.startswith("error")
        except (OSError, subprocess.TimeoutExpired) as e:
            msg, bad = str(e), True
        if bad and msg not in self.errors:
            self.errors.add(msg)
            print("keylog: hyprctl eval failed: %s" % msg, file=sys.stderr, flush=True)
        return not bad

    def arm(self):
        return self.hypr(lua_arm(self.raw, self.all_keys, self.paused))

    def is_locked(self):
        try:
            p = subprocess.run(self.lock_cmd, capture_output=True, text=True, timeout=2)
            return p.stdout.strip() == "true"
        except (OSError, subprocess.TimeoutExpired):
            return False

    # -- key handling
    def push(self, text):
        self.items = (self.items + [{"text": text, "at": now_ms()}])[-6:]
        self.dirty = True

    def on_raw(self, line):
        parts = line.split(" ")
        if parts[0] == "K" and len(parts) >= 3:
            try:
                code = None if parts[1] == "?" else int(parts[1])
            except ValueError:
                return
            down = parts[2] != "0"
            hyprt = int(parts[3]) if len(parts) > 3 and parts[3].isdigit() else 0
            self.on_key(code, down, hyprt)
        elif parts[0] == "S":
            self.emit({"type": "submap", "name": line[2:], "source": "lua"})

    def on_key(self, code, down, hyprt):
        mods = set(self.held.values())
        mod = MOD_NAMES.get(code) if code is not None else None
        ev = {"type": "key", "code": code, "key": raw_name(code) if code is not None else None,
              "label": key_label(code), "state": "down" if down else "up",
              "mods": [m for m in MOD_ORDER if m in mods]}
        if hyprt:
            ev["hyprTimeMs"] = hyprt
        if mod:
            if down:
                self.held[code] = mod
                self.lone[code] = True
            else:
                self.held.pop(code, None)
                if self.lone.pop(code, False):
                    self.push(mods_label(set(self.held.values()) | {mod}))
        elif down:
            for k in self.lone:
                self.lone[k] = False
            ev["combo"] = combo(mods, code)
            self.push(ev["combo"])
        self.emit(ev)

    # -- overlay for the bar widget
    def write_overlay(self, force=False):
        t = now_ms()
        if not force and not (self.dirty and t - self.last_overlay >= 50) and t - self.last_overlay < 1000:
            return
        data = {"recording": True, "startedAt": self.started, "heartbeat": t, "showKeys": self.show_keys,
                "monitor": self.monitor,
                "allKeys": self.all_keys, "paused": self.paused, "items": [] if self.paused else self.items}
        tmp = self.overlay + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f)
        os.replace(tmp, self.overlay)
        self.dirty, self.last_overlay = False, t

    # -- Hyprland event socket
    def socket_reader(self):
        path = os.environ.get("BF_HYPR_SOCKET2") or os.path.join(
            os.environ.get("XDG_RUNTIME_DIR", ""), "hypr", os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", ""),
            ".socket2.sock")
        while not self.stop.is_set():
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                s.connect(path)
            except OSError:
                s.close()
                self.stop.wait(2)
                continue
            s.settimeout(1.0)
            buf = b""
            while not self.stop.is_set():
                try:
                    data = s.recv(65536)
                except socket.timeout:
                    continue
                except OSError:
                    break
                if not data:
                    break
                buf += data
                *lines, buf = buf.split(b"\n")
                for raw in lines:
                    name, _, value = raw.decode("utf-8", "replace").partition(">>")
                    if name in HYPR_EVENTS:
                        self.q.put({"type": "hypr", "event": name, "data": value, "time": now_ms(), "mono": mono_ms()})
                        if name == "configreloaded":
                            self.rearm.set()
            s.close()

    # -- main loop
    def run(self):
        os.umask(0o077)
        os.makedirs(self.rt, mode=0o700, exist_ok=True)
        with open(self.raw, "a"):
            pass
        os.chmod(self.raw, 0o600)
        self.out = open(os.path.join(self.bundle, "events.jsonl"), "a", buffering=1, encoding="utf-8")
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(sig, lambda *_: self.stop.set())
        self.emit({"type": "session", "event": "start", "allKeys": self.all_keys})
        self.arm()
        threading.Thread(target=self.socket_reader, daemon=True).start()
        fd = os.open(self.raw, os.O_RDONLY)
        buf = b""
        next_watch = 0.0
        deadline = time.monotonic() + self.max_s if self.max_s > 0 else None

        def drain():
            nonlocal buf
            while True:
                data = os.read(fd, 65536)
                if not data:
                    break
                buf += data
            *lines, buf = buf.split(b"\n")
            for line in lines:
                if line:
                    self.on_raw(line.decode("utf-8", "replace"))
            while not self.q.empty():
                self.emit(self.q.get_nowait())

        while not self.stop.is_set():
            drain()
            t = time.monotonic()
            if self.rearm.is_set():
                self.rearm.clear()
                self.arm()
            if t >= next_watch:
                next_watch = t + 1.0
                locked = self.is_locked()
                if locked != self.paused:
                    self.paused = locked
                    self.emit({"type": "lock", "locked": locked})
                    self.dirty = True
                self.arm()
            if deadline and t >= deadline and not self.autostopped:
                self.autostopped = True
                self.emit({"type": "session", "event": "timeout", "seconds": self.max_s})
                if self.cli and os.access(self.cli, os.X_OK):
                    subprocess.Popen([self.cli, "record", "stop", "--auto"], start_new_session=True,
                                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                else:
                    self.stop.set()
            self.write_overlay()
            self.stop.wait(0.01)

        self.hypr(LUA_DISARM)
        drain()
        self.emit({"type": "session", "event": "stop"})
        self.out.close()
        os.close(fd)
        for p in (self.overlay, self.raw):
            try:
                os.remove(p)
            except OSError:
                pass


# ------------------------------------------------------------------- render --
def fmt(ms):
    ms = max(0, int(ms))
    return "%02d:%06.3f" % (ms // 60000, (ms % 60000) / 1000)


def bind_hits(binds, mods, code, submap):
    if code is None:
        return []
    mask = sum(MOD_BITS.get(m, 0) for m in set(mods))
    name = raw_name(code).upper()
    cands = {name.replace("_", "")} | {x.replace("_", "") for x in BIND_ALIASES.get(name, [])}
    hits = []
    for b in binds if isinstance(binds, list) else []:
        if b.get("mouse") or b.get("release"):
            continue
        if (b.get("submap") or "") != (submap or ""):
            continue
        try:
            if int(b.get("modmask", -1)) != mask:
                continue
        except (TypeError, ValueError):
            continue
        key = str(b.get("key") or "").upper().replace("_", "")
        if (key and key in cands) or (b.get("keycode") and int(b.get("keycode")) == code):
            hits.append(b.get("description") or ("%s %s" % (b.get("dispatcher", ""), b.get("arg", ""))).strip())
    return hits


def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def render(bundle):
    evs = []
    try:
        with open(os.path.join(bundle, "events.jsonl")) as f:
            for line in f:
                try:
                    evs.append(json.loads(line))
                except ValueError:
                    pass
    except OSError:
        pass
    evs.sort(key=lambda e: e.get("mono", 0))
    session = load_json(os.path.join(bundle, "session.json"), {})
    binds = load_json(os.path.join(bundle, "binds.json"), [])
    start = session.get("startedAt") or (evs[0].get("time") if evs else now_ms())
    vstart = session.get("videoStartedAt")
    video_t0 = vstart + VIDEO_TRIM_MS if vstart else None
    all_keys = bool(session.get("allKeys"))

    body, submap, keys, hits, locks, combos = [], "", 0, [], 0, []
    for e in evs:
        t = e.get("time", start)
        vid = fmt(t - video_t0) if video_t0 is not None and t >= video_t0 else "  --:--.---"
        prefix = "%s  %s  " % (fmt(t - start), vid)
        kind = e.get("type")
        if kind == "key":
            keys += 1
            if e.get("state") == "down":
                label = e.get("combo") or combo(set(e.get("mods") or []), e.get("code"))
                matched = bind_hits(binds, e.get("mods") or [], e.get("code"), submap)
                note = ("   => Hyprland bind: " + "; ".join(matched)) if matched else ""
                if matched:
                    hits.append("%s -> %s" % (label, "; ".join(matched)))
                if e.get("code") is None or MOD_NAMES.get(e.get("code")) is None:
                    combos.append(label)
                body.append(prefix + "key  down  %s%s" % (label, note))
            else:
                body.append(prefix + "key  up    %s" % e.get("label", "?"))
        elif kind == "submap":
            submap = e.get("name") or ""
            body.append(prefix + "submap  %s" % (submap or "(default)"))
        elif kind == "hypr":
            if e.get("event") == "submap":
                submap = e.get("data") or ""
            body.append(prefix + "%s  %s" % (e.get("event"), e.get("data", "")))
        elif kind == "lock":
            locks += 1 if e.get("locked") else 0
            body.append(prefix + ("LOCKED: key log paused" if e.get("locked") else "unlocked: key log resumed"))
        elif kind == "session":
            body.append(prefix + "session %s" % e.get("event"))

    end = evs[-1].get("time", start) if evs else start
    head = [
        "Troubleshooting recording (omarchy-beta-feedback)",
        "Started   %s" % time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(start / 1000)),
        "Duration  %s" % fmt(end - start),
        "Video     %s" % (session.get("video") or "(none)"),
        "          video times are approximate (about +/-0.3 s); the keys are also drawn on screen in the video",
        "Keys      %s" % ("every key was recorded" if all_keys else
                          "letters, digits, punctuation and space show as • unless Ctrl, Alt or Super was held"),
        "Binds     a key marked '=> Hyprland bind' matched a Hyprland keybinding (best effort)",
        "",
        "elapsed    video        event",
    ]
    with open(os.path.join(bundle, "timeline.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(head + body) + "\n")
    summary = {"events": len(evs), "keys": keys, "durationMs": end - start, "lockPauses": locks,
               "bindHits": hits[:50], "combos": combos[:200], "video": session.get("video") or ""}
    with open(os.path.join(bundle, "summary.json"), "w") as f:
        json.dump(summary, f)
    print(json.dumps(summary))


# --------------------------------------------------------------------- main --
def main(argv):
    p = argparse.ArgumentParser(prog="keylog.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--bundle", required=True)
    r.add_argument("--runtime", required=True)
    r.add_argument("--cli", default="")
    r.add_argument("--all-keys", action="store_true")
    r.add_argument("--show-keys", action="store_true")
    r.add_argument("--max", type=int, default=1200)
    r.add_argument("--monitor", default="")
    d = sub.add_parser("render")
    d.add_argument("--bundle", required=True)
    lu = sub.add_parser("lua")
    lu.add_argument("what", choices=["arm", "disarm"])
    lu.add_argument("--raw", default="")
    lu.add_argument("--all-keys", action="store_true")
    lu.add_argument("--paused", action="store_true")
    a = p.parse_args(argv)
    if a.cmd == "run":
        Recorder(a).run()
    elif a.cmd == "render":
        render(a.bundle)
    elif a.what == "arm":
        sys.stdout.write(lua_arm(a.raw, a.all_keys, a.paused))
    else:
        sys.stdout.write(LUA_DISARM)


if __name__ == "__main__":
    main(sys.argv[1:])
