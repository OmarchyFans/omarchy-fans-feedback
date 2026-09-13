#!/usr/bin/env python3
"""omarchy-feedback daemon: the always-on event log and the optional screen replay.

  feedbackd.py            run in the foreground (the CLI starts it with setsid)

One instance per session, guarded by flock on $RT/daemon.lock. It
  - reads Hyprland's event socket (.socket2.sock) for window, workspace, layer,
    monitor and submap events, and samples the pointer position after focus
    and layer changes;
  - arms a Lua key listener with `hyprctl eval` and folds its raw lines into
    shortcut / navigation-key events (typed text is never logged);
  - pauses the key listener while the session is locked (checked once a second
    on Hyprland's command socket, same rule as omarchy-hyprland-session-locked);
  - writes everything to one-minute JSONL segments on tmpfs, keeping 12 minutes;
  - runs gpu-screen-recorder in replay mode while armed (auto-disarm: 30 min, lock, monitor change);
  - answers one-line JSON requests on $RT/ctl.sock (status, snap, pause, resume, arm, disarm, stop);
  - keeps $RT/status.json fresh (the bar chip reads it; its mtime is the heartbeat).
Nothing here is written inside ~/.config/omarchy/plugins.
"""
import sys

sys.dont_write_bytecode = True  # never create __pycache__ inside the plugin folder (it reloads the shell)

import ctypes  # noqa: E402
import errno  # noqa: E402
import fcntl  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import select  # noqa: E402
import signal  # noqa: E402
import socket  # noqa: E402
import subprocess  # noqa: E402
import time  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import of_events  # noqa: E402
import of_keys  # noqa: E402

VERSION = "0.3.0"


def runtime_dir():
    return os.environ.get("OF_RUNTIME") or os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "omarchy-feedback")


def state_dir():
    return os.environ.get("OF_STATE") or os.path.join(
        os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state"), "omarchy-feedback")


def load_settings():
    try:
        with open(os.path.join(state_dir(), "settings.json")) as f:
            v = json.load(f)
            return v if isinstance(v, dict) else {}
    except (OSError, ValueError):
        return {}


def save_settings(data):
    d = state_dir()
    os.makedirs(d, exist_ok=True)
    tmp = os.path.join(d, ".settings.json.tmp")
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, os.path.join(d, "settings.json"))


class Inotify:
    """IN_MODIFY on one file through libc, so the loop sleeps until the Lua side writes."""
    IN_MODIFY, IN_CLOEXEC, IN_NONBLOCK = 0x2, 0o2000000, 0o4000

    def __init__(self, path):
        self.fd = -1
        try:
            libc = ctypes.CDLL("libc.so.6", use_errno=True)
            fd = libc.inotify_init1(self.IN_CLOEXEC | self.IN_NONBLOCK)
            if fd < 0:
                return
            if libc.inotify_add_watch(fd, path.encode(), self.IN_MODIFY) < 0:
                os.close(fd)
                return
            self.fd = fd
        except (OSError, AttributeError):
            self.fd = -1

    def drain(self):
        if self.fd < 0:
            return
        try:
            while os.read(self.fd, 4096):
                pass
        except OSError:
            pass


class Daemon:
    def __init__(self):
        self.rt = runtime_dir()
        self.state = state_dir()
        self.raw = os.path.join(self.rt, "keys.raw")
        self.ctl_path = os.path.join(self.rt, "ctl.sock")
        self.status_path = os.path.join(self.rt, "status.json")
        self.hyprctl = os.environ.get("OF_HYPRCTL", "hyprctl")
        self.all_keys = os.environ.get("OF_ALL_KEYS") == "1"
        self.running = True
        self.locked = False
        self.settings = load_settings()
        self.user_paused = bool(self.settings.get("paused"))
        self.decoder = of_keys.KeyDecoder()
        self.log = None
        self.lua_ok = False
        self.lua_error = ""
        self.events_written = 0
        self.started = of_events.now_ms()
        self.s2 = None
        self.s2_buf = b""
        self.raw_fd = -1
        self.raw_buf = b""
        self.last_status = 0.0
        self.next_lock_check = 0.0
        self.next_rearm = 0.0
        self.next_truncate = time.monotonic() + 3600
        self.replay = None          # {"proc", "monitor", "armedAt", "seconds", "ipc", "dir"}
        self.replay_note = ""       # why the last replay ended

    # ---------------------------------------------------------------- basics --
    def emit(self, ev):
        if self.user_paused and ev.get("type") not in ("daemon", "mark"):
            return
        self.log.write(ev)
        self.events_written += 1

    def hypr_eval(self, chunk):
        try:
            p = subprocess.run([self.hyprctl, "eval", chunk], capture_output=True, text=True, timeout=3)
            msg = (p.stdout + p.stderr).strip()
            ok = p.returncode == 0 and not msg.startswith("error")
        except (OSError, subprocess.TimeoutExpired) as e:
            msg, ok = str(e), False
        if not ok:
            self.lua_error = msg[:300]
        return ok

    def key_paused(self):
        return self.locked or self.user_paused

    def arm(self):
        self.lua_ok = self.hypr_eval(of_keys.lua_arm(self.raw, self.all_keys, self.key_paused()))
        return self.lua_ok

    # ---------------------------------------------------------------- status --
    def status(self):
        return {"running": True, "pid": os.getpid(), "version": VERSION, "startedAt": self.started,
                "heartbeat": of_events.now_ms(), "locked": self.locked, "paused": self.user_paused,
                "keyListener": self.lua_ok, "keyListenerError": "" if self.lua_ok else self.lua_error,
                "hyprland": self.s2 is not None, "events": self.events_written,
                "keepMinutes": self.log.keep if self.log else of_events.KEEP_MINUTES,
                "replay": self.replay_status()}

    # -------------------------------------------------------------- replay --
    # gpu-screen-recorder in replay mode keeps the last N seconds in RAM and
    # writes nothing until asked. It runs with argv[0] "omarchy-feedback-replay"
    # so Omarchy's `pkill -f "^gpu-screen-recorder"` (its own recorder's stop)
    # does not kill it. Saving goes through its -ipc socket (ofctl save-replay).
    REPLAY_ARGV0 = "omarchy-feedback-replay"

    def replay_status(self):
        r = self.replay
        if not r:
            return {"armed": False, "lastEnded": self.replay_note}
        return {"armed": True, "monitor": r["monitor"], "armedAt": r["armedAt"], "seconds": r["seconds"],
                "ipc": r["ipc"], "dir": r["dir"], "pid": r["proc"].pid,
                "maxSeconds": self.replay_max_s(), "lastEnded": self.replay_note}

    @staticmethod
    def replay_max_s():
        return int(os.environ.get("OF_REPLAY_MAX_S", "1800"))

    def focused_monitor(self):
        mons = of_events.hypr_json("monitors", []) or []
        for m in mons:
            if isinstance(m, dict) and m.get("focused"):
                return m.get("name")
        return mons[0].get("name") if mons and isinstance(mons[0], dict) else None

    def arm_replay(self, seconds=120):
        if self.replay:
            return {"ok": True, **self.replay_status()}
        if self.locked:
            return {"ok": False, "error": "the screen is locked"}
        gsr = os.environ.get("OF_GSR") or "gpu-screen-recorder"
        exe = gsr if os.path.isabs(gsr) else next(
            (os.path.join(p, gsr) for p in os.environ.get("PATH", "").split(os.pathsep)
             if os.access(os.path.join(p, gsr), os.X_OK)), None)
        if not exe:
            return {"ok": False, "error": "gpu-screen-recorder is not installed"}
        mon = self.focused_monitor()
        if not mon:
            return {"ok": False, "error": "no monitor found"}
        seconds = max(10, min(int(seconds or 120), 600))
        out = os.path.join(self.state, "replays")
        os.makedirs(out, mode=0o700, exist_ok=True)
        ipc = os.path.join(self.rt, "replay.sock")
        argv = [self.REPLAY_ARGV0, "-w", mon, "-c", "mp4", "-f", "30", "-r", str(seconds),
                "-replay-storage", "ram", "-k", "auto", "-q", "medium", "-cursor", "yes",
                "-write-first-frame-ts", "yes", "-o", out, "-ipc", ipc]
        log = open(os.path.join(self.rt, "replay.log"), "ab")
        try:
            proc = subprocess.Popen(argv, executable=exe, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                    start_new_session=True)
        except OSError as e:
            return {"ok": False, "error": str(e)}
        finally:
            log.close()
        self.replay = {"proc": proc, "monitor": mon, "armedAt": of_events.now_ms(), "seconds": seconds,
                       "ipc": ipc, "dir": out}
        self.replay_note = ""
        self.log.write({"type": "daemon", "event": "replay-armed", "monitor": mon, "seconds": seconds})
        self.write_status(force=True)
        return {"ok": True, **self.replay_status()}

    def disarm_replay(self, why="disarmed"):
        r = self.replay
        if not r:
            return {"ok": True, "armed": False}
        self.replay = None
        self.replay_note = why
        p = r["proc"]
        if p.poll() is None:
            try:
                p.send_signal(signal.SIGINT)  # replay mode: stop without saving
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait(timeout=2)
            except OSError:
                pass
        self.log.write({"type": "daemon", "event": "replay-disarmed", "why": why})
        self.write_status(force=True)
        return {"ok": True, "armed": False, "why": why}

    def check_replay(self):
        r = self.replay
        if not r:
            return
        if r["proc"].poll() is not None:
            self.disarm_replay("recorder exited (code %s); see replay.log" % r["proc"].returncode)
        elif of_events.now_ms() - r["armedAt"] > self.replay_max_s() * 1000:
            self.disarm_replay("auto-disarmed after %d minutes" % (self.replay_max_s() // 60))
        elif self.locked:
            self.disarm_replay("auto-disarmed when the screen locked")

    def write_status(self, force=False):
        t = time.monotonic()
        if not force and t - self.last_status < 5:
            return
        self.last_status = t
        tmp = self.status_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.status(), f)
        os.replace(tmp, self.status_path)

    # ------------------------------------------------------------ hyprland --
    def connect_socket2(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            s.connect(os.path.join(of_events.hypr_dir(), ".socket2.sock"))
        except OSError:
            s.close()
            return False
        s.setblocking(False)
        self.s2 = s
        return True

    def on_socket2(self):
        try:
            data = self.s2.recv(65536)
        except BlockingIOError:
            return
        except OSError:
            data = b""
        if not data:
            # Hyprland went away (restart or logout). Exit; the widget starts a fresh daemon.
            self.emit({"type": "daemon", "event": "hyprland-gone"})
            self.running = False
            return
        self.s2_buf += data
        *lines, self.s2_buf = self.s2_buf.split(b"\n")
        for raw in lines:
            ev = of_events.parse_hypr_line(raw.decode("utf-8", "replace"))
            if not ev:
                continue
            self.emit(ev)
            if ev["event"] == "configreloaded":
                self.next_rearm = 0
            if ev["event"] == "focusedmon" and self.replay and ev.get("monitor") != self.replay["monitor"]:
                self.disarm_replay("auto-disarmed: focus moved to monitor %s" % ev.get("monitor"))
            if ev["event"] in of_events.CURSOR_AFTER and not self.user_paused:
                pos = of_events.hypr_json("cursorpos")
                if isinstance(pos, dict) and "x" in pos:
                    self.emit({"type": "cursor", "x": pos.get("x"), "y": pos.get("y"), "after": ev["event"]})

    def check_lock(self):
        mons = of_events.hypr_json("monitors")
        if mons is None:
            return
        locked = of_events.session_locked(mons)
        if locked != self.locked:
            self.locked = locked
            self.decoder.reset()
            self.emit({"type": "lock", "locked": locked})
            self.arm()
            self.write_status(force=True)

    # ----------------------------------------------------------------- keys --
    def on_raw(self):
        while True:
            try:
                data = os.read(self.raw_fd, 65536)
            except BlockingIOError:
                data = b""
            if not data:
                break
            self.raw_buf += data
        *lines, self.raw_buf = self.raw_buf.split(b"\n")
        for line in lines:
            if line:
                for ev in self.decoder.feed(line.decode("utf-8", "replace")):
                    self.emit(ev)

    def truncate_raw(self):
        self.on_raw()
        try:
            os.truncate(self.raw, 0)
            os.lseek(self.raw_fd, 0, os.SEEK_SET)
        except OSError:
            pass
        self.raw_buf = b""

    # ------------------------------------------------------------ control --
    def handle(self, req):
        cmd = req.get("cmd")
        if cmd == "status":
            return {"ok": True, **self.status()}
        if cmd == "snap":
            dest, minutes = req.get("dest"), int(req.get("minutes") or 10)
            if not dest or not os.path.isabs(dest):
                return {"ok": False, "error": "dest must be an absolute path"}
            self.emit({"type": "mark", "note": str(req.get("note") or "")[:200]})
            n = of_events.snapshot(self.log.dir, dest, minutes)
            return {"ok": True, "path": dest, "events": n}
        if cmd in ("pause", "resume"):
            self.user_paused = cmd == "pause"
            self.settings["paused"] = self.user_paused
            save_settings(self.settings)
            self.decoder.reset()
            self.log.write({"type": "daemon", "event": "paused" if self.user_paused else "resumed"})
            self.arm()
            self.write_status(force=True)
            return {"ok": True, "paused": self.user_paused}
        if cmd == "arm":
            return self.arm_replay(req.get("seconds") or 120)
        if cmd == "disarm":
            return self.disarm_replay("disarmed")
        if cmd == "stop":
            self.running = False
            return {"ok": True}
        return {"ok": False, "error": "unknown command %r" % cmd}

    def on_ctl(self, server):
        try:
            conn, _ = server.accept()
        except OSError:
            return
        with conn:
            conn.settimeout(2)
            buf = b""
            try:
                while b"\n" not in buf and len(buf) < 65536:
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    buf += chunk
                req = json.loads(buf.decode().strip() or "{}")
                resp = self.handle(req if isinstance(req, dict) else {})
            except (ValueError, OSError) as e:
                resp = {"ok": False, "error": str(e)}
            try:
                conn.sendall((json.dumps(resp) + "\n").encode())
            except OSError:
                pass

    # ---------------------------------------------------------------- main --
    def run(self):
        os.umask(0o077)
        os.makedirs(self.rt, mode=0o700, exist_ok=True)
        os.chmod(self.rt, 0o700)
        lock = open(os.path.join(self.rt, "daemon.lock"), "a+")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print("feedbackd: already running", file=sys.stderr)
            return 0
        lock.seek(0)
        lock.truncate()
        lock.write(str(os.getpid()))
        lock.flush()

        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(sig, lambda *_: setattr(self, "running", False))

        self.log = of_events.SegmentLog(os.path.join(self.rt, "seg"),
                                        int(os.environ.get("OF_KEEP_MINUTES", of_events.KEEP_MINUTES)))
        of_keys.ensure_private_file(self.raw)
        self.raw_fd = os.open(self.raw, os.O_RDONLY | os.O_NONBLOCK)
        os.lseek(self.raw_fd, 0, os.SEEK_END)
        ino = Inotify(self.raw)

        try:
            os.unlink(self.ctl_path)
        except OSError:
            pass
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(self.ctl_path)
        os.chmod(self.ctl_path, 0o600)
        server.listen(8)
        server.setblocking(False)

        # Hyprland may still be starting (post-boot): wait up to 30 s for its socket.
        deadline = time.monotonic() + float(os.environ.get("OF_HYPR_WAIT", "30"))
        while self.running and not self.connect_socket2() and time.monotonic() < deadline:
            time.sleep(1)
        if self.s2 is None:
            print("feedbackd: Hyprland event socket not available", file=sys.stderr)
            self.running = False

        self.log.write({"type": "daemon", "event": "start", "version": VERSION})
        self.check_lock()
        self.arm()
        self.next_rearm = time.monotonic() + 60
        self.write_status(force=True)

        tick = float(os.environ.get("OF_TICK", "1.0"))
        while self.running:
            fds = [server]
            if self.s2 is not None:
                fds.append(self.s2)
            if ino.fd >= 0:
                fds.append(ino.fd)
            timeout = tick if ino.fd >= 0 else min(tick, 0.25)
            try:
                ready, _, _ = select.select(fds, [], [], timeout)
            except InterruptedError:
                ready = []
            except OSError as e:
                if e.errno == errno.EINTR:
                    ready = []
                else:
                    raise
            if ino.fd >= 0 and ino.fd in ready:
                ino.drain()
            self.on_raw()
            if self.s2 is not None and self.s2 in ready:
                self.on_socket2()
            if server in ready:
                self.on_ctl(server)
            now = time.monotonic()
            if now >= self.next_lock_check:
                self.next_lock_check = now + tick
                self.check_lock()
            if now >= self.next_rearm:
                self.next_rearm = now + 60
                self.arm()
            if now >= self.next_truncate:
                self.next_truncate = now + 3600
                self.truncate_raw()
            self.check_replay()
            self.write_status()

        self.disarm_replay("daemon stopped")
        self.hypr_eval(of_keys.LUA_DISARM)
        self.on_raw()
        self.log.write({"type": "daemon", "event": "stop"})
        self.log.close()
        for p in (self.ctl_path, self.status_path, self.raw):
            try:
                os.remove(p)
            except OSError:
                pass
        server.close()
        return 0


def main():
    return Daemon().run()


if __name__ == "__main__":
    sys.exit(main())
