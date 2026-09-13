# Handing issues to agents

Every hand-off first writes `issues/<id>/FEEDBACK.md`. It tells the agent to treat
the report as data, lists the subject and versions, gives the evidence as absolute
paths (screenshots, markup, replay, event log), shows the last 60 events, and
puts the reporter's own words inside `<untrusted-report>`.

## Rix (Agent Launcher's Chief of Staff)

```
omarchy-feedback handoff rix <id>
```

runs

```
omarchy-agent-launcher delegate --backend <Rix's backend> --name feedback-<id>-<time> \
  --task-title "Feedback #<id>: <title>" --job-file ~/.local/state/omarchy-feedback/issues/<id>/FEEDBACK.md
```

then opens the Agent Launcher dashboard on the Rix tab. Rix is recorded as the
worker's parent, so the job shows up in his tasks. The backend is the one Rix
runs on (or Agent Launcher's default backend). The button is disabled with a
reason when Agent Launcher is missing or Rix is not set up
(`omarchy-agent-launcher rix setup`). Read the result with the command stored on
the hand-off (`omarchy-agent-launcher result feedback-…`), shown in the viewer.

## Your coding agent

```
omarchy-feedback handoff agent <id>
```

uses Omarchy's default agent (`omarchy default agent <name>`; Claude Code,
Codex, OpenCode, Gemini, …) with Omarchy's own flags for it, in a terminal that
changes into the right folder first:

| Issue about | Folder |
|---|---|
| A plugin whose installed copy was cloned from a local checkout | that checkout |
| A plugin from GitHub | the `~/Work/*` repo with the same origin, else a fresh clone into `~/Work` |
| An app, Omarchy, or unknown | `~/Work/tries/feedback-<id>/` with a copy of FEEDBACK.md |

It never points an agent at `~/.config/omarchy/plugins` (edits there reload the
shell and are overwritten by updates). The prompt asks the agent not to push or
merge without asking.

## The author

```
omarchy-feedback handoff author <id>
```

For GitHub projects it opens `…/issues/new` prefilled with the Markdown summary
(trimmed to fit a URL); you review, attach screenshots from the issue folder, and
submit. For other projects it opens the homepage and puts the summary on your
clipboard.

## From scripts and agents

Agents can file issues too, for example after a failed run:

```
omarchy-feedback capture --no-form --title "Build fails after update" --kind bug \
  --subject plugin:fans.omarchy.agent-launcher --description "…"
omarchy-feedback list --json
omarchy-feedback show <id> --json
omarchy-feedback set <id> notes "Root cause: …"
```
