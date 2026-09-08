# Author guide

## Prerequisites

- Your plugin repo on GitHub, `gh` logged in with push rights.
- The Beta Feedback plugin installed (`omarchy plugin add …/omarchy-beta-feedback`)
  and, for comfort, its CLI symlinked by `install.sh`.

## 1. Enroll the repo

```
omarchy-beta-feedback author init ~/Work/my-plugin      # add --push to push staging right away
```

What it does, idempotently: copies `BetaFeedback.qml` into the repo, writes
`.beta-feedback.json` (`repo`, `stableBranch`, `betaBranch`, `test`), creates
`staging` from your default branch, creates the labels `beta-feedback`,
`approved`, `fixed-in-beta`, `released`, `wontfix`, and registers the repo in
`~/.config/omarchy-beta-feedback/author-repos.json`.

Set `"test"` in `.beta-feedback.json` to your test command (defaults to
`tests/run.sh` when that file exists). The agent must pass it before a PR is
opened.

## 2. Wire the SDK

Inside your `KeyboardPanel`, as a **direct child** (next to `PanelKeyCatcher`):

```qml
KeyboardPanel {
  id: panel
  …
  PanelKeyCatcher { … }
  BetaFeedback { pluginId: root.moduleName; opened: panel.open }
}
```

Optional keyboard support for the opt-in dialog: give it an id and call
`betaFeedback.handleKey(event)` first in your key catcher. The component is
invisible unless the user has the Beta Feedback plugin installed, so shipping
it costs nothing for everyone else.

Plugins without a panel (bar chip only) can still take reports: add a menu
entry that runs `omarchy-beta-feedback report --plugin <id>` (no screenshot,
no click trace).

Commit `BetaFeedback.qml` + `.beta-feedback.json`, push `main` and `staging`.

## 3. Work the inbox

```
omarchy-beta-feedback author inbox           # TUI: show / approve / repair / promote / reject
omarchy-beta-feedback author inbox --json    # for scripts and agents
```

Statuses: `new → approved → repairing → pr-open → fixed-in-beta → confirmed → released`, or `rejected`.

- **approve** adds the `approved` label. **reject** adds `wontfix` and closes.
- **repair** creates a worktree on `fix/issue-N` from `origin/staging`, renders
  `templates/repair-prompt.md`, runs the agent (config `agent`, default
  `claude`), runs your tests, commits, pushes, opens a PR against `staging`.
  With `--merge` it also squash-merges (auto-merge if the repo allows it) and
  labels the issue `fixed-in-beta`; otherwise merge the PR yourself and run
  `author fixed <repo> N`.
- Testers on the beta channel then get the "fix ready" notification. Their
  verdict arrives as a comment; `confirmed` means "works for me".
- **promote** opens (or with `--merge`, merges) a PR `staging → main`, bumps the
  manifest version with `--bump patch|minor|major`, labels the issues
  `released`, comments, and closes them. Testers on beta are nudged back to
  stable.

## Agents

`~/.config/omarchy-beta-feedback/config.json`:

```json
{
  "agent": "claude",
  "agents": { "aider": "aider --yes --message-file \"$BF_PROMPT\"" }
}
```

`claude` runs `claude -p --permission-mode acceptEdits` with tools limited to
editing and git/tests inside the worktree. `hermes` runs a one-shot Hermes
session (see hermes.md). `codex` runs `codex exec --full-auto`. Custom entries
run in the worktree with `BF_WORKDIR` and `BF_PROMPT`.

The report text is passed as **untrusted** input and the prompt says so; the
agent never pushes or merges, the CLI does, and promotion to `main` is always
your command.

## Marketplace note

Enrolling adds `BetaFeedback.qml` to your plugin. It spawns one process (the
CLI) and reads one file (`.git/HEAD`); it does not capture the screen (it uses
`Item.grabToImage` on your own panel) or the keyboard. Expect the marketplace's
baseline to list `process-spawn` for it, nothing more.
