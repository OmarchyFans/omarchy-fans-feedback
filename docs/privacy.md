# What Feedback records

Feedback exists to capture context you would otherwise forget. That makes what it
records, where, and for how long worth stating exactly.

## Always on (while you are logged in)

The event log starts with the bar chip and keeps the **last 12 minutes** in
one-minute files under `$XDG_RUNTIME_DIR/omarchy-feedback/seg`. That folder is
in RAM, readable only by you (0700 folder, 0600 files), and gone after a reboot.

| Recorded | Not recorded |
|---|---|
| Which window got focus (app class and window title) | Anything you type: letters, digits, punctuation and space are replaced before they reach even the RAM file |
| Windows opening and closing, workspace and monitor changes | Mouse clicks (Hyprland does not expose them) |
| Shell surfaces showing and hiding (menu, bar panels) | Clipboard contents |
| Shortcuts (a key pressed with Ctrl, Alt or Super) and navigation keys (arrows, Enter, Esc, F-keys) | The screen (unless you arm the replay) |
| Where the pointer was right after a focus or layer change | Anything while the screen is locked (keys are paused) |

Pause it any time from the bar panel (**Pause event log**) or with
`omarchy-feedback pause`. The pause survives restarts until you resume.

Window titles can contain private text (a document name, a web page title). They
are part of the log because they are the most useful clue to what you were doing.

## Screen replay (only while armed)

**Arm screen replay** in the panel starts `gpu-screen-recorder` in replay mode
on the focused monitor. It keeps the last 2 minutes **in memory** and writes
nothing unless you file an issue. It switches itself off after 30 minutes, when
the screen locks, or when focus moves to another monitor. The chip shows a red
dot while it runs.

## When you file an issue

Only then is anything written to disk, into
`~/.local/state/omarchy-feedback/issues/<id>/`:

- the monitor screenshot and the focused-window crop,
- your Tensaku markup, if you made one,
- the last 10 minutes of the event log,
- the replay video, if armed,
- versions (Omarchy, Hyprland, Quickshell, kernel), theme and monitor layout,
- your title, description and notes.

Delete an issue from the bar panel (trash icon) or with `omarchy-feedback delete <id>`;
its folder goes with it.

## When you hand an issue off

Nothing is sent anywhere by filing. A hand-off is always your click:

- **Rix** and **your coding agent** run on this machine and read the issue folder.
- **Author** opens a GitHub new-issue page prefilled with the Markdown summary.
  Nothing is posted until you press Submit there, and screenshots and the replay
  are attached only if you drag them in.

The web viewer can only *ask* for a hand-off; your desktop shows a notification
and runs it only after you confirm.

## The web viewer

It listens on `127.79.33.1:7741`, a loopback address other machines cannot reach.
Other web pages in your browser cannot use it either: it checks the exact Host
header, requires a per-machine key (stored 0600 in the state folder and passed to
the viewer window in the part of the URL that is never sent over the network),
refuses cross-site writes, and cannot delete issues or start agents.
