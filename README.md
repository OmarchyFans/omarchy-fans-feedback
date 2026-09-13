# Feedback for Omarchy

`fans.omarchy.feedback` records feedback about **anything on your desktop**: an
Omarchy plugin, an app, a window, or Omarchy itself. No per-plugin setup, no
server, nothing leaves your machine unless you send it.

Press **SUPER + ALT + B** (or middle-click the 󰃤 bug in the bar) the moment
something goes wrong or you have an idea:

1. A screenshot of the monitor and the focused window is taken **before**
   anything of Feedback's appears on screen.
2. The last 10 minutes of the **event log** are attached: window focus, workspace
   and layer changes, shortcuts and navigation keys, pointer position at focus
   changes. Typed text is never recorded.
3. If you **armed the screen replay**, the last 2 minutes of the monitor are saved
   as a video.
4. Tensaku opens so you can draw, add arrows and write on the screenshot.
5. A short form: what it is about (guessed from what was focused), bug or feature,
   title, description.

The issue lands in a local database. Left-click the bug to see the list. Each
issue can be handed to:

- **Rix**, the Chief of Staff in [Agent Launcher](https://github.com/OmarchyFans/omarchy-fans-agent-launcher),
  which triages it as a worker job.
- **Your coding agent** (Omarchy's default agent, e.g. Claude Code), opened in
  the project's folder with the issue brief.
- **The author**, as a prefilled GitHub issue you review before submitting, or
  the project's homepage with the report on your clipboard.

The **viewer** (`omarchy-feedback open`, or Open on an issue) is a local web app
that replays what led up to the issue: the video synced with the event timeline,
or a step-through of the events over the screenshot when no replay was armed.
You or an agent can mark up screenshots with pens, arrows, boxes and text notes,
edit the description and notes, and download a **PDF** or **Markdown** summary.
It installs as a web app and follows your Omarchy theme.

## Install

```
omarchy plugin add https://github.com/OmarchyFans/omarchy-fans-feedback --enable
~/.config/omarchy/plugins/fans.omarchy.feedback/install.sh
omarchy restart shell
```

`install.sh` asks before each step: the `omarchy-feedback` command on your PATH,
the SUPER + ALT + B keybinding (it never replaces an existing binding), a Feedback
section in the Omarchy menu, and the viewer as an installed web app.
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
