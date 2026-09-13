#!/usr/bin/env python3
"""Who made the thing a report is about.

  of_subject.py candidates <pending-dir>   JSON list, best guess first
  of_subject.py plugin <id>                JSON subject for one installed plugin
  of_subject.py normalize-repo <url>       https://github.com/owner/name form, or the input

A subject is {type: plugin|app|omarchy|unknown, id, name, version, repo, author, label}.
Sources:
  plugin   ~/.config/omarchy/plugins/<id>/manifest.json + the clone's git origin
           (a local-path origin is followed one hop), else the cached marketplace catalog
  app      the focused window's pid -> /proc/<pid>/exe -> pacman -Qo -> pacman -Qi (Name, Version, URL);
           Omarchy web apps (class chrome-<host>__...) -> https://<host>
  omarchy  pacman -Qi omarchy
"""
import sys

sys.dont_write_bytecode = True

import json  # noqa: E402
import os  # noqa: E402
import re  # noqa: E402
import subprocess  # noqa: E402

OMARCHY_REPO = "https://github.com/basecamp/omarchy"
BUILTIN_LAYER = re.compile(r"^omarchy-")
SHELL_CLASSES = ("org.quickshell", "quickshell", "omarchy-shell")


def plugins_dir():
    return os.environ.get("OF_PLUGINS_DIR") or os.path.join(
        os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config"), "omarchy", "plugins")


def run(argv, timeout=5):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return p.stdout if p.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def load(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def normalize_repo(url):
    url = (url or "").strip()
    m = re.match(r"^(?:git@|ssh://git@)([^:/]+)[:/](.+?)(?:\.git)?/?$", url)
    if m:
        return "https://%s/%s" % (m.group(1), m.group(2))
    m = re.match(r"^https?://([^/]+)/(.+?)(?:\.git)?/?$", url)
    if m:
        return "https://%s/%s" % (m.group(1), m.group(2))
    return url


def git_origin(path, hops=2):
    url = run(["git", "-C", path, "remote", "get-url", "origin"]).strip()
    if url and hops > 0 and (url.startswith("/") or url.startswith("file://")):
        local = url[7:] if url.startswith("file://") else url
        return git_origin(local, hops - 1) or url
    return url


def catalog_repo(plugin_id):
    for path in (os.path.join(os.path.expanduser("~"), ".cache", "omarchy-plugin-audit", "catalog.json"),):
        cat = load(path, {})
        for p in (cat.get("plugins") or []) if isinstance(cat, dict) else []:
            if isinstance(p, dict) and p.get("id") == plugin_id and p.get("repo"):
                return p["repo"]
    return ""


def plugin_subject(plugin_id):
    d = os.path.join(plugins_dir(), plugin_id)
    m = load(os.path.join(d, "manifest.json"), {})
    if not m:
        return None
    direct = run(["git", "-C", d, "remote", "get-url", "origin"]).strip()
    local = ""
    if direct.startswith("/") or direct.startswith("file://"):
        local = direct[7:] if direct.startswith("file://") else direct
        origin = git_origin(local, hops=1)
    else:
        origin = direct
    repo = normalize_repo(origin) if origin and not origin.startswith("/") else ""
    repo = repo or normalize_repo(catalog_repo(plugin_id))
    name = m.get("name") or plugin_id
    return {"type": "plugin", "id": plugin_id, "name": name, "version": m.get("version") or "",
            "repo": repo, "localCheckout": local, "author": m.get("author") or "",
            "label": "Plugin: %s (%s)" % (name, plugin_id)}


def installed_plugins():
    out = []
    try:
        names = sorted(os.listdir(plugins_dir()))
    except OSError:
        return out
    for n in names:
        if n.startswith("."):
            continue
        s = plugin_subject(n)
        if s:
            out.append(s)
    return out


def pacman_info(pkg):
    info = {}
    for line in run(["pacman", "-Qi", pkg]).splitlines():
        k, sep, v = line.partition(":")
        if sep:
            info[k.strip()] = v.strip()
    return info


def omarchy_subject():
    info = pacman_info("omarchy")
    return {"type": "omarchy", "id": "omarchy", "name": "Omarchy", "version": info.get("Version", ""),
            "repo": normalize_repo(info.get("URL") or OMARCHY_REPO) or OMARCHY_REPO, "author": "Omarchy",
            "label": "Omarchy itself (desktop, bar, menus, keybindings)"}


def app_subject(win):
    if not isinstance(win, dict) or not win.get("class"):
        return None
    cls, title, pid = win.get("class") or "", win.get("title") or "", win.get("pid")
    subj = {"type": "app", "id": cls, "name": cls, "version": "", "repo": "", "author": "",
            "label": "App: %s — %s" % (cls, title[:60])}
    m = re.match(r"^(?:chrome|brave|chromium)-([^_]+)__", cls)
    if m:
        host = m.group(1)
        subj.update({"name": host, "repo": "https://" + host, "author": host, "label": "Web app: %s" % host})
        return subj
    exe = ""
    if isinstance(pid, int) and pid > 0:
        try:
            exe = os.readlink("/proc/%d/exe" % pid)
        except OSError:
            exe = ""
    if exe:
        owner = run(["pacman", "-Qoq", exe]).strip().splitlines()
        if owner:
            info = pacman_info(owner[0])
            subj.update({"name": info.get("Name", owner[0]), "version": info.get("Version", ""),
                         "repo": info.get("URL", ""), "author": info.get("Packager", "").split("<")[0].strip(),
                         "package": owner[0],
                         "label": "App: %s %s — %s" % (info.get("Name", owner[0]), info.get("Version", ""), title[:50])})
    return subj


def candidates(pending):
    win = load(os.path.join(pending, "activewindow.json"), {})
    out = []
    app = app_subject(win)
    if app:
        out.append(app)
    events = []
    try:
        with open(os.path.join(pending, "events.jsonl")) as f:
            for line in f:
                try:
                    events.append(json.loads(line))
                except ValueError:
                    pass
    except OSError:
        pass
    cap = load(os.path.join(pending, "meta.json"), {}).get("captureMs") or 0
    recent_shell = any(e.get("type") == "layer" and e.get("event") == "openlayer"
                       and BUILTIN_LAYER.match(e.get("namespace") or "") and e.get("namespace") != "omarchy-bar"
                       and (not cap or cap - e.get("t", 0) < 30000)
                       for e in events[-40:])
    om = omarchy_subject()
    plugins = installed_plugins()
    # Plugin panels are Quickshell windows titled with the manifest name
    # ("Omarchy Help"); such a window is about that plugin, or else the shell.
    shell_win = (win.get("class") or "").lower() in SHELL_CLASSES
    title = (win.get("title") or "").strip().lower()
    owner = next((p for p in plugins if shell_win and title and
                  (p.get("name") or "").strip().lower() in (title, title.split(" — ")[0])), None)
    if recent_shell or not app or shell_win:
        out.insert(0, om)
    else:
        out.append(om)
    if owner:
        plugins.remove(owner)
        out.insert(0, owner)
    out.extend(plugins)
    out.append({"type": "unknown", "id": "", "name": "Something else", "version": "", "repo": "", "author": "",
                "label": "Something else / not sure"})
    return out


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    if argv[0] == "candidates":
        print(json.dumps(candidates(argv[1])))
    elif argv[0] == "plugin":
        s = plugin_subject(argv[1])
        if not s:
            return 1
        print(json.dumps(s))
    elif argv[0] == "normalize-repo":
        print(normalize_repo(argv[1]))
    else:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
