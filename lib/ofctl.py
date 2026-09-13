#!/usr/bin/env python3
"""Client for the feedback daemon's control socket.

  ofctl.py status                      JSON status (exit 3 when the daemon is not running)
  ofctl.py snap <dest> [minutes]       copy the last N minutes of events into dest
  ofctl.py pause | resume | stop | disarm
  ofctl.py arm [seconds]                start the screen replay buffer
  ofctl.py save-replay <dest.mp4>      write the replay buffer to dest (exit 4 when not armed)
  ofctl.py describe <events.jsonl>     human timeline, one event per line

`snap` falls back to reading the tmpfs segments directly when the daemon is down.
"""
import sys

sys.dont_write_bytecode = True

import json  # noqa: E402
import os  # noqa: E402
import socket  # noqa: E402
import time  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import feedbackd  # noqa: E402
import of_events  # noqa: E402


def request(req, timeout=5.0):
    path = os.path.join(feedbackd.runtime_dir(), "ctl.sock")
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(path)
        s.sendall((json.dumps(req) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
        return json.loads(buf.decode() or "{}")
    except (OSError, ValueError):
        return None
    finally:
        s.close()


def save_replay(dest, timeout=60.0):
    """Ask the armed recorder to write its buffer, then move the file (and its .ts) to dest.

    Exit 0 saved, 4 not armed, 1 failed. Runs in the CLI, so the daemon never blocks on it.
    """
    st = request({"cmd": "status"}, timeout=2)
    rep = (st or {}).get("replay") or {}
    if not rep.get("armed"):
        print(json.dumps({"ok": False, "armed": False}))
        return 4
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(rep["ipc"])
        s.sendall(b'{"id":1,"name":"save-replay"}\n')
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
        reply = json.loads(buf.decode().splitlines()[0])
    except (OSError, ValueError, IndexError) as e:
        print(json.dumps({"ok": False, "armed": True, "error": "recorder did not answer: %s" % e}))
        return 1
    finally:
        s.close()
    src = reply.get("data") if reply.get("result") == "ok" else None
    if not src or not os.path.isfile(src):
        print(json.dumps({"ok": False, "armed": True, "error": reply.get("data") or "no file"}))
        return 1
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    import shutil
    shutil.move(src, dest)
    if os.path.exists(src + ".ts"):
        shutil.move(src + ".ts", dest + ".ts")
    print(json.dumps({"ok": True, "path": dest, "bytes": os.path.getsize(dest)}))
    return 0


def main(argv):
    if not argv:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cmd = argv[0]
    if cmd == "status":
        r = request({"cmd": "status"}, timeout=2)
        if r is None:
            print(json.dumps({"running": False}))
            return 3
        print(json.dumps(r))
        return 0
    if cmd == "snap":
        if len(argv) < 2:
            return 2
        dest = os.path.abspath(argv[1])
        minutes = int(argv[2]) if len(argv) > 2 else 10
        r = request({"cmd": "snap", "dest": dest, "minutes": minutes})
        if r is None:
            n = of_events.snapshot(os.path.join(feedbackd.runtime_dir(), "seg"), dest, minutes)
            r = {"ok": True, "path": dest, "events": n, "fallback": True}
        print(json.dumps(r))
        return 0 if r.get("ok") else 1
    if cmd in ("pause", "resume", "stop", "disarm"):
        r = request({"cmd": cmd})
        print(json.dumps(r if r is not None else {"ok": False, "error": "daemon not running"}))
        return 0 if r and r.get("ok") else 1
    if cmd == "arm":
        r = request({"cmd": "arm", "seconds": int(argv[1]) if len(argv) > 1 else 120}, timeout=10)
        print(json.dumps(r if r is not None else {"ok": False, "error": "daemon not running"}))
        return 0 if r and r.get("ok") else 1
    if cmd == "save-replay":
        return save_replay(os.path.abspath(argv[1]))
    if cmd == "describe":
        for ev in of_events.read_events(argv[1]):
            t = ev.get("t", 0)
            print("%s  %s" % (time.strftime("%H:%M:%S", time.localtime(t / 1000)), of_events.describe(ev)))
        return 0
    print("ofctl: unknown command %r" % cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
