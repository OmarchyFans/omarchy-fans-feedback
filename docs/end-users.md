# What the beta program collects (end-user guide)

## Joining a beta

Open the 󰃤 chip in the bar. **Beta programs** lists your installed plugins:

- **Join beta** appears for plugins whose author runs a beta program (they
  ship a `.beta-feedback.json`). After joining, that plugin's panel shows the
  bug button.
- **Set up beta…** appears for plugins installed from a git repo on this
  machine (your own plugins). It opens `omarchy-beta-feedback author init` in a
  terminal; see [authors.md](authors.md).
- Other plugins have no beta program until their author adds one.

A plugin whose author wired in the SDK also asks you once, from its own panel.
Nothing is recorded before you join.

## While you are enrolled

- The last **10 mouse presses inside that plugin's panel** are kept in memory
  (which control, which button). Never key presses, never text you typed,
  never anything outside the panel. They are forgotten when the panel closes
  and never written to disk until you press the bug button.
- Enrollment ends by itself after **5 days of use** (days on which you opened
  the panel). You can leave earlier from the Beta Feedback bar chip.

## When you press the bug button

1. A picture of **that panel only** is taken (not your screen) and opened in
   Tensaku so you can crop, blur, draw and write on it. Enter keeps it, Escape
   keeps the original.
2. A floating window asks: bug or feature, a title, a description.
3. You see the whole report before it is sent: the picture, the clicks, the
   plugin's version and commit, your Omarchy / Hyprland / Quickshell versions,
   theme and monitor layout, and up to 100 lines of the shell log that mention
   the plugin.
4. You choose how to send it: with your GitHub login through `gh`, in your
   browser as a prefilled issue, or **save only** (nothing leaves the machine).
   The picture goes to your clipboard for you to paste into the issue.

Reports are GitHub issues on the plugin's repo, public like any issue there,
under your GitHub account. Your local copy stays in
`~/.local/state/omarchy-beta-feedback/bundles/`.

## Troubleshooting recording

For bugs you have to *show*, for example a shortcut that does nothing. Nothing
is recorded until you press **Record focused screen** in the 󰃤 panel (or run
`omarchy-beta-feedback record start`); the chip pulses red while it runs.

What it records:

- **Video of the focused monitor**, made by Omarchy's own screen recorder and
  saved to your Videos folder like any screen recording. No audio.
- **Key presses** as seen by Hyprland: which key, pressed or released, which
  modifiers were held. By default letters, digits, punctuation and space are
  written as `•`; they become readable only while Ctrl, Alt or Super is held
  (shortcuts, not text). Turn on **Include letters and digits** only when the
  bug is about typing.
- **Desktop events**: active window (class and title), workspace, monitor
  focus, keyboard layout, submap, windows opening and closing, config reloads.
- **At the start**: your Hyprland keybindings, keyboard layout and options, and
  whether an input method (fcitx5, ibus) is running.

With **Show keys on screen** on, each key combination is also drawn at the
bottom of the recorded monitor, so the video itself shows what was pressed.

Safeguards:

- The key log **pauses while the screen is locked** (checked every second), so
  your unlock password is not logged.
- It **stops by itself after 20 minutes**.
- Keys are captured with a listener registered in Hyprland at runtime; nothing
  is added to your config, no root access is needed, and the listener is
  removed when the recording stops.

When you stop it you get the report form. The report shows a timeline of the
keys and events (and marks key presses that matched a Hyprland keybinding),
and you choose where it goes: the plugin's repo, Omarchy's issue tracker for
desktop bugs, or **save only**. GitHub has no upload API, so you drag the video
into the issue yourself. Everything stays in
`~/.local/state/omarchy-beta-feedback/bundles/*-recording/` until you delete it.

## After that

The bar chip polls the repo hourly. When the author's fix lands on the beta
branch you get a notification; *Update now* switches your copy of the plugin
to that branch (Omarchy validates it and rolls back if it is broken). Try it,
then press *It works* or *Still broken*. When the fix is released you are
nudged back to the stable branch.
