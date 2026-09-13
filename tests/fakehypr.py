#!/usr/bin/env python3
"""A stand-in Hyprland for tests: serves .socket.sock and .socket2.sock in a dir.

  fakehypr.py <dir>

.socket.sock answers j/monitors (LOCK in solitaryBlockedBy while <dir>/locked
exists), j/cursorpos, j/activewindow, j/layers, j/clients from <dir>/<name>.json
when present. Every line appended to <dir>/emit is broadcast on .socket2.sock.
Exits when <dir>/quit appears.
"""
import sys

sys.dont_write_bytecode = True

import json  # noqa: E402
import os  # noqa: E402
import select  # noqa: E402
import socket  # noqa: E402

d = sys.argv[1]
os.makedirs(d, exist_ok=True)
paths = {n: os.path.join(d, n) for n in (".socket.sock", ".socket2.sock")}
servers = {}
for name, p in paths.items():
    try:
        os.unlink(p)
    except OSError:
        pass
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(p)
    s.listen(16)
    servers[name] = s

emit = os.path.join(d, "emit")
open(emit, "a").close()
emit_f = open(emit, "rb")
emit_f.seek(0, os.SEEK_END)
subs = []


def answer(cmd):
    name = cmd[2:] if cmd.startswith("j/") else cmd
    override = os.path.join(d, name + ".json")
    if os.path.exists(override):
        with open(override) as f:
            return f.read()
    if name == "monitors":
        blocked = ["WINDOWED", "CANDIDATE"] + (["LOCK"] if os.path.exists(os.path.join(d, "locked")) else [])
        return json.dumps([{"name": "eDP-1", "x": 0, "y": 0, "width": 1920, "height": 1200, "scale": 1.5,
                            "focused": True, "solitaryBlockedBy": blocked}])
    if name == "cursorpos":
        return json.dumps({"x": 640, "y": 12})
    return "[]"


open(os.path.join(d, "ready"), "w").close()
while not os.path.exists(os.path.join(d, "quit")):
    r, _, _ = select.select(list(servers.values()), [], [], 0.05)
    for s in r:
        conn, _ = s.accept()
        if s is servers[".socket.sock"]:
            conn.settimeout(1)
            try:
                cmd = conn.recv(4096).decode().strip()
                conn.sendall(answer(cmd).encode())
            except OSError:
                pass
            conn.close()
        else:
            subs.append(conn)
    data = emit_f.read()
    if data:
        for c in list(subs):
            try:
                c.sendall(data)
            except OSError:
                subs.remove(c)
for c in subs:
    c.close()
