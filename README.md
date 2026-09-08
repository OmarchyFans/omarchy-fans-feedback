# Beta Feedback for Omarchy plugins

`fans.omarchy.beta-feedback` — a beta program you can bolt onto any Omarchy
shell plugin you author, with **no server and no running costs**.

- **End users** opt in from your plugin's panel and get a small 󰃤 button. One
  press grabs a picture of *that panel only*, opens it in Tensaku so they can
  draw on it, attaches the last 10 clicks inside the panel plus version info
  and a shell-log excerpt, and files it as a GitHub issue on your repo with
  their own GitHub login. Enrollment ends by itself after 5 days of use.
- **You** triage the queue in a terminal (`author inbox`), approve reports, let
  an agent (Claude Code by default, Hermes or anything else optional) fix them
  on a `staging` branch through a PR, and promote confirmed fixes to `main`.
- **Testers** get a desktop notification when a fix is ready: *Update now* moves
  their plugin clone to `staging`; *It works* / *Still broken* posts the verdict
  on the issue; *Back to stable* returns to `main` after the release.

The transport is GitHub Issues + labels. State lives in
`~/.local/state/omarchy-beta-feedback/` (a small SQLite queue for authors,
JSON for testers).

## Install (as an end user)

```
omarchy plugin add https://github.com/modpunk/omarchy-beta-feedback --enable
```

That is enough for the 󰃤 button to appear inside enrolled plugins. The bar
chip shows your enrollments, reports and update buttons. Optional extras
(CLI on PATH, menu entries): `~/.config/omarchy/plugins/fans.omarchy.beta-feedback/install.sh`.

## Enroll your own plugin (as an author)

```
omarchy-beta-feedback author init ~/path/to/your-plugin
```

This vendors `BetaFeedback.qml`, writes `.beta-feedback.json`, creates a
`staging` branch and the labels. Then add one line inside your `KeyboardPanel`:

```qml
BetaFeedback { pluginId: root.moduleName; opened: panel.open }
```

Commit, push `main` and `staging`, done. See [docs/authors.md](docs/authors.md),
[docs/end-users.md](docs/end-users.md) (what is collected) and
[docs/hermes.md](docs/hermes.md) (agents).

## The loop

```
tester: bug button → annotate → submit          author: author inbox → approve → repair (agent)
   GitHub issue (label beta-feedback)     ←→        PR → staging (label fixed-in-beta)
tester: notification → Update now → test → It works   author: promote → main (label released)
tester: notification → Back to stable
```

## Development

`tests/run.sh` runs the whole loop under throwaway XDG dirs with `gh`,
`tensaku`, `claude`, notifications and the shell tools stubbed (`tests/stubs/`).
`omarchy plugin validate .` checks the manifest.

MIT.
