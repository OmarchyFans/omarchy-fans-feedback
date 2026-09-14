# Marketplace submission draft (omacom/omarchy-plugin-marketplace)

**Plugin id:** fans.omarchy.feedback
**Repo:** https://github.com/OmarchyFans/omarchy-fans-feedback
**Category:** Developer Tools  **Tags:** feedback, bugs, issues, agents

**Summary:** Record feedback about anything on the desktop. SUPER + ALT + B takes a
screenshot, attaches the last minutes of an event log (window focus and shortcuts,
never typed text) and an optional in-memory screen replay, opens Tensaku for
markup, and files a local issue. Issues can be handed to Agent Launcher's Rix, the
Omarchy default coding agent, or the project author (a prefilled GitHub issue the
user reviews). A local web viewer replays the lead-up and exports PDF or Markdown.

**Capabilities the baseline scan will list, all by design:**

- `screen-capture`: `grim` for the screenshot at capture time; `gpu-screen-recorder`
  in replay mode only while the user arms it (RAM buffer, auto-off after 30 minutes,
  on lock, on monitor change).
- `input-capture`: a Hyprland Lua `input.keyboard.key` listener registered with
  `hyprctl eval`. Letters, digits, punctuation and space are replaced in Lua before
  anything is written; the listener pauses while the session is locked; the log
  lives in `$XDG_RUNTIME_DIR` and keeps 12 minutes. No /dev/input, no root.
- `process-spawn`: the bar widget runs the bundled CLI; the CLI runs hyprctl,
  grim, ffmpeg, tensaku, gum, git, sqlite3 (Python stdlib), chromium (headless PDF).
- `network`: a loopback-only HTTP server on 127.79.33.1:7741 for the viewer
  (exact Host check, per-machine token, same-origin writes only). `git clone` of a
  plugin's own origin when handing an issue to the coding agent. No other endpoints.
- `clipboard`: `wl-copy` puts the Markdown summary on the clipboard for non-GitHub authors.
- `hyprland-control`: `hyprctl eval` for the key listener only.
- `writes-user-config`: `install.sh`, each step confirmed: a keybinding appended to
  `~/.config/hypr/bindings.lua` (never replacing an existing one), a menu section in
  `~/.config/omarchy/extensions/omarchy-menu.jsonc`, a web-app entry.
- `installer`: `install.sh` / `uninstall.sh`.
- `package-manager`: read-only `pacman -Q` / `-Qi` / `-Qoq` lookups to name the
  package, version and project URL of the app a report is about. Nothing is installed.

Local triage with omarchy-plugin-audit (2026-09-12): no findings; review-required for
package-manager, network, filesystem-write and process-spawn context.

**Executable resolution:** the bar widget runs only the plugin's own `bin/omarchy-feedback` by
absolute path with a fixed argv (no shell strings). That CLI, `install.sh` and `uninstall.sh` reset
`PATH` to root-owned folders (`/usr/share/omarchy/bin:/usr/local/bin:/usr/bin:/bin`) before running
anything, so nothing in a user-writable folder such as `~/.local/bin` can stand in for a tool; Agent
Launcher is called by its installed plugin path. `tests/run.sh` checks that a shadow `jq`/`python3`
earlier in `PATH` is ignored.

**Secret handling:** text that looks like a password, key, token or account number is masked
before it is stored (window titles, form fields, notes, markup notes); saved screenshots are read
with the locally installed `tesseract` and matching regions painted black with `ffmpeg`; findings
keep only the masked form, raise a critical desktop notification asking the user to rotate, and
block the public author hand-off until marked rotated. All local, no network.

**Not present:** privilege escalation, service management (the daemon is started by
the widget), dynamic code loading, credential access, remote endpoints.

**Verification:** `tests/run.sh` (fake Hyprland, stubbed tools), `tests/test_viewer.py`
(forged-header attacks on the viewer), `omarchy plugin validate .`.
