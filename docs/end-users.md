# What the beta program collects (end-user guide)

You only ever see the 󰃤 button in a plugin whose author enrolled it **and**
after you said *Join* in that plugin's panel. Nothing is recorded before that.

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

## After that

The bar chip polls the repo hourly. When the author's fix lands on the beta
branch you get a notification; *Update now* switches your copy of the plugin
to that branch (Omarchy validates it and rolls back if it is broken). Try it,
then press *It works* or *Still broken*. When the fix is released you are
nudged back to the stable branch.
