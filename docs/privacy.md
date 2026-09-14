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

## Passwords, keys, tokens and account numbers

Feedback hides these before it writes anything, everywhere text comes in: window titles
(before they reach even the in-memory event log), the saved window details, your title,
description and notes, and text notes you put on a markup.

| Looks like | Stored as | Asks you to rotate |
|---|---|---|
| A password (`password=…`, `--password …`, `Password: …`, `https://user:pass@…`), a private key block | `********` | yes |
| An API key or token (GitHub, GitLab, Anthropic, OpenAI, AWS, Slack, Stripe, Google, Hugging Face, npm, JWTs, `token=`/`secret=`/`Bearer` values, long random strings) | first and last 4 characters: `ghp_…9f3e` | yes |
| A card number (Luhn-checked), IBAN or social security number | `4111…1111` | yes |
| A UUID, long hex id or long number | `550e…0000` | no |

The value itself is never stored, only the masked form. After an issue is saved, the
screenshot, the window crop and marked-up images are read with OCR (tesseract) and anything
that looks like a secret is painted black in place. A sample of screen-replay frames is read
too; a secret there cannot be cut out of a video, so you are told and can delete the replay
(**Delete replay** in the bar list, or `omarchy-feedback delete-replay <id>`).

When anything is found you get a critical notification: *possible GitHub token ghp_…9f3e
captured in feedback #12 (title of the kitty window): it may be compromised, rotate it as soon
as possible.* The issue shows a red warning in the bar list and the viewer until you mark it
rotated, and sending it to the author (a public issue) stays locked until then. Exports, agent
briefs and the author page are redacted once more on the way out.

Issues saved by an older version are scanned and cleaned when the recorder starts. OCR and
patterns cannot catch everything (a password typed into an unlabelled field, text too small or
blurred to read): look at your screenshots before sending them anywhere.

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

**Save Markdown** and **Save PDF** write `feedback-<id>-<title>.md|.pdf` into your Downloads
folder (`xdg-user-dir DOWNLOAD`), replacing an earlier save of the same issue. **Show in Files**
opens your file manager with that file selected; it only accepts a file this issue saved into
Downloads, never any other path.
