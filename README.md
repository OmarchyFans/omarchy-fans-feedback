# Feedback for Omarchy

**Catch a bug or an idea the moment it happens, anywhere on your desktop, and turn it
into a fix.** One keypress captures a screenshot and what led up to it. Feedback files it in a
local issue list and hands it to Rix, your coding agent or the project's author. Your
screenshots and logs never leave the machine unless you send them.

## Features

- **Report from anywhere.** Press SUPER + ALT + B (or middle-click the 󰃤 bug) over any
  Omarchy plugin, app, window or Omarchy itself. No per-plugin setup.
- **Screenshot first.** The monitor and the focused window are captured before
  anything of Feedback's appears on screen.
- **Knows what led up to it.** An always-on event log keeps the last 12 minutes of window
  focus, workspace and layer changes, shortcuts and the pointer position, and pauses while the
  screen is locked. **Typed text is never recorded.**
- **Knows when it's out of date.** A dot on the chip and a banner in the popup say when a new version is out and what changed; *Update…* walks you through it.
- **Optional screen replay.** Arm it from the bar and the last 2 minutes stay in memory,
  saved as a video only when you file an issue. It turns itself off after 30 minutes, on lock,
  or on a monitor change.
- **Mark it up.** Draw arrows, boxes and notes on the screenshot in Tensaku right away, or
  later in the viewer.
- **Knows what it's about.** Feedback guesses whether the report concerns a plugin, an app or
  Omarchy, and fills in its version, project link and author.
- **Local issue list.** Click the bug to see new, triaged, sent and fixed issues, with
  status, notes and delete.
- **Hand it off in one click:**
  - **Rix**, the Chief of Staff in [Agent Launcher](https://github.com/OmarchyFans/omarchy-fans-agent-launcher),
    triages it as a worker job.
  - **Your coding agent** (Omarchy's default, e.g. Claude Code) opens in the project's
    folder with an issue brief that treats the report as untrusted input.
  - **The author** gets a prefilled issue on the project's repository that you review
    before posting.
- **Replay viewer.** A local web app plays the video in sync with the event timeline, or
  steps through the events over the screenshot. It follows your Omarchy theme and installs
  as a web app.
- **Export.** Save any issue as a PDF or Markdown summary into your Downloads folder; the viewer
  shows the full path with **Show in Files** and **Copy path**.
- **Scriptable.** `omarchy-feedback capture --no-form ...` lets agents and scripts file
  issues too.
- **Secrets never recorded.** Passwords become `********`; API keys, tokens and card or account
  numbers keep only their ends (`ghp_…9f3e`) before anything is saved: window titles in the event log,
  your title, description, notes and markup notes. Screenshots are read with OCR and any secret is
  painted black. If one was captured, Feedback tells you right away that it may be compromised and
  to rotate it, and keeps the author hand-off locked until you mark it rotated.
- **Private by design.** The viewer listens on loopback only, and scripts and agents
  never post anything to the internet. Pause the log at any time. See
  [docs/privacy.md](docs/privacy.md).

## How a report works

1. Press **SUPER + ALT + B**: the screenshot, window crop and the last 10 minutes of
   events are saved (plus the replay, if armed).
2. Tensaku opens for markup; Enter saves, Escape skips.
3. A short form: what it is about (guessed from what was focused), bug or feature,
   title, description.
4. The issue appears in the bar list and in the viewer (`omarchy-feedback open`).

## Install

```
omarchy plugin add https://github.com/OmarchyFans/omarchy-fans-feedback --enable
~/.config/omarchy/plugins/fans.omarchy.feedback/install.sh
omarchy restart shell
```

`install.sh` asks before each step: the `omarchy-feedback` command on your PATH,
the SUPER + ALT + B keybinding (it never replaces an existing binding), a Feedback
section in the Omarchy menu, and the viewer as an installed web app.
### Updates

About once every six hours, when the popup opens, it fetches this repository's
`manifest.json` (one small HTTPS request, no personal data). If a newer version
is out, a dot appears on the bug chip and the popup shows what changed, from
`CHANGELOG.md`. *Update…* opens a terminal that runs `omarchy plugin update`
(it shows the diff and asks), then `install.sh` (asks again), then offers to
restart the recorder. *Later* hides that version. Set `"update_check": false`
in `~/.config/omarchy-feedback/config.json` to turn the check off. By hand:

```sh
omarchy plugin update fans.omarchy.feedback
~/.config/omarchy/plugins/fans.omarchy.feedback/install.sh
omarchy-feedback daemon restart
```

See [docs/update-alerts.md](docs/update-alerts.md) for how it is built.

## Remove

```
~/.config/omarchy/plugins/fans.omarchy.feedback/uninstall.sh   # add --purge to also delete your issues
omarchy plugin remove fans.omarchy.feedback --yes
```

`uninstall.sh` stops the recorder, removes the keybinding, menu section, web app and command link
that `install.sh` added, and keeps `~/.local/state/omarchy-feedback` unless you pass `--purge`.

## Commands

```
omarchy-feedback capture [--source key] [--no-annotate]
omarchy-feedback capture --no-form --title T [--kind bug|feature] [--subject auto|omarchy|app|plugin:<id>] [--description D]
omarchy-feedback list [--status open|all|<status>] [--json]
omarchy-feedback show <id> [--json]
omarchy-feedback set <id> status|notes|title|description|kind <value>
omarchy-feedback handoff rix|agent|author <id>
omarchy-feedback open [id]
omarchy-feedback export <id> --md|--pdf [--out FILE]
omarchy-feedback arm [seconds] | disarm | pause | resume
omarchy-feedback daemon ensure|status|stop|restart
omarchy-feedback update-check | update-dismiss <version> | update-run
omarchy-feedback secrets <id> | secrets scan <id> | secrets scan-all | secrets rotated <id>
omarchy-feedback delete-replay <id>
```

`capture --no-form` lets scripts and agents file issues too.

## How it works

- `lib/feedbackd.py`: one detached daemon per session, started by the bar chip.
  It reads Hyprland's event socket, arms a Lua key listener with `hyprctl eval`
  (no root, no /dev/input), pauses keys while the screen is locked, and writes
  one-minute JSONL segments to `$XDG_RUNTIME_DIR/omarchy-feedback/seg` (RAM,
  12 minutes kept). While armed it runs `gpu-screen-recorder` in replay mode
  (RAM buffer, saved over its IPC socket), and it serves the viewer on
  `http://127.79.33.1:7741`.
- Issues: `~/.local/state/omarchy-feedback/feedback.db` (SQLite) and
  `~/.local/state/omarchy-feedback/issues/<id>/`.
- Hand-offs write `FEEDBACK.md`: the reporter's words inside
  `<untrusted-report>`, the evidence as absolute paths. See [docs/agents.md](docs/agents.md).
- What is recorded and what is not: [docs/privacy.md](docs/privacy.md).

## Development

`tests/run.sh` runs everything against a fake Hyprland and stubbed desktop tools
under throwaway XDG folders (groups: unit lua daemon capture handoff viewer
install). `tests/test_viewer.py` attacks the viewer with forged Host, Origin and
Sec-Fetch-Site headers. `omarchy plugin validate .` checks the manifest.

MIT.
