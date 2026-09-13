"""Key events for omarchy-feedback: the Hyprland Lua listener, redaction, labels.

Keys come from Hyprland's own Lua event `input.keyboard.key`, registered at
runtime with `hyprctl eval`: no root, no /dev/input, nothing added to the
user's config. The Lua side writes bare "K <code> <state> <timeMs>" lines to a
0600 file in XDG_RUNTIME_DIR. Letters, digits, punctuation and space are
written as "?" unless Ctrl, Alt or Super is held (or all_keys was chosen), so
typed text never reaches even the tmpfs file.

KeyDecoder turns those raw lines into timeline events: one event per key
press that is a shortcut or a navigation key, plus a lone modifier tap. Key
releases and modifier presses are folded in, so the log stays small.
"""
import os
import re
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
REDACTED = "•"


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
        return REDACTED
    n = raw_name(code)
    return FRIENDLY.get(n, n if len(n) <= 2 else n.title())


def mods_label(mods):
    return "+".join(m for m in MOD_ORDER if m in mods)


def combo(mods, code):
    return "+".join([m for m in MOD_ORDER if m in mods] + [key_label(code)])


# ---------------------------------------------------------------------- lua --
LUA_GLOBAL = "ofrec"


def lua_path(path):
    if not re.fullmatch(r"[A-Za-z0-9_./@+-]+", path):
        raise ValueError("refusing a path Lua cannot take verbatim: %r" % path)
    return '"%s"' % path


def lua_arm(raw, all_keys=False, paused=False):
    """Idempotent: a live listener only gets its pause flag updated."""
    shown = ", ".join("[%d]=true" % c for c in NON_TEXT)
    reveal = ", ".join("[%d]=true" % c for c in REVEAL)
    return f"""local paused, all = {str(paused).lower()}, {str(all_keys).lower()}
local r = _G.{LUA_GLOBAL}
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
_G.{LUA_GLOBAL} = r
"""


LUA_DISARM = f"""local r = _G.{LUA_GLOBAL}
if r then
  if r.k then pcall(function() r.k:remove() end) end
  if r.s then pcall(function() r.s:remove() end) end
  if r.f then pcall(function() r.f:close() end) end
  _G.{LUA_GLOBAL} = nil
end
"""


# ------------------------------------------------------------------ decoder --
class KeyDecoder:
    """Raw Lua lines in, timeline events out (a list per line, often empty)."""

    def __init__(self):
        self.held = {}   # modifier keycode -> name
        self.lone = {}   # modifier keycode -> no other key pressed since it went down

    def reset(self):
        self.held.clear()
        self.lone.clear()

    def feed(self, line):
        parts = line.split(" ")
        if parts[0] == "S":
            return [{"type": "submap", "name": line[2:]}]
        if parts[0] != "K" or len(parts) < 3:
            return []
        try:
            code = None if parts[1] == "?" else int(parts[1])
        except ValueError:
            return []
        down = parts[2] != "0"
        mod = MOD_NAMES.get(code) if code is not None else None
        if mod:
            if down:
                self.held[code] = mod
                self.lone[code] = True
                return []
            self.held.pop(code, None)
            if self.lone.pop(code, False):
                mods = set(self.held.values()) | {mod}
                return [{"type": "key", "combo": mods_label(mods), "mods": [m for m in MOD_ORDER if m in mods],
                         "key": raw_name(code), "code": code, "tap": True}]
            return []
        if not down:
            return []
        for k in self.lone:
            self.lone[k] = False
        mods = set(self.held.values())
        ev = {"type": "key", "combo": combo(mods, code), "mods": [m for m in MOD_ORDER if m in mods],
              "code": code, "key": raw_name(code) if code is not None else None}
        if code is None:
            ev["redacted"] = True
        return [ev]


def bind_hits(binds, mods, code, submap=""):
    """Hyprland binds (hyprctl binds -j) that a key press matched, best effort."""
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


def ensure_private_file(path):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.close(fd)
    os.chmod(path, 0o600)
