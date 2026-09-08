# Marketplace submission draft — omacom/omarchy-plugin-marketplace

**Repo:** https://github.com/modpunk/omarchy-beta-feedback
**Plugin id:** fans.omarchy.beta-feedback  **Category:** Developer Tools  **Tags:** feedback, beta, bugs, github

**Summary:** A serverless beta program for plugin authors. End users opt in
per plugin, get a bug button inside the plugin's panel, and file annotated
reports as GitHub issues with their own login. Authors triage in a TUI, let an
agent fix on a staging branch, and testers get update-now notifications.

**Capabilities to expect in the baseline scan (all by design):**
- `process-spawn` — the panel runs the bundled CLI; the CLI runs git, gh, tensaku, jq, sqlite3.
- `network` — `gh api` / `curl` to api.github.com only (issue lists, search, comments) and `git fetch` of the plugin's own origin. No other endpoints; no token of the author's is ever placed on an end user's machine.
- `clipboard` — `wl-copy` puts the reporter's own annotated screenshot on their clipboard so they can paste it into the issue.
- `installer` — optional `install.sh` (symlink + menu entry, confirmed per step) and `uninstall.sh`.
- `writes-user-config` — only `~/.config/omarchy/extensions/omarchy-menu.jsonc` (install.sh, opt-in) and the plugin's own dirs.
- **Not present:** `screen-capture` (grim/slurp are not used; the panel image comes from `Item.grabToImage` on the plugin's own item), `input-capture`, `privilege`, `service-management`, `dynamic-code-load`.

**Verification:** `tests/run.sh` (stubbed end-to-end loop), `omarchy plugin validate .`.
