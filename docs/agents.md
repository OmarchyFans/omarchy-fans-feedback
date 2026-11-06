# Handing issues to agents

Every hand-off first writes `issues/<id>/FEEDBACK.md`. It tells the agent to treat
the report as data, lists the subject and versions, gives the evidence as absolute
paths (screenshots, markup, replay, event log), shows the last 60 events, and
puts the reporter's own words inside `<untrusted-report>`.

## Rix (Singularix's Chief of Staff)

```
omarchy-feedback handoff rix <id>
```

runs

```
<plugin>/bin/omarchy-agent-launcher delegate --backend <Rix's backend> --name feedback-<id>-<time> \
  --task-title "Feedback #<id>: <title>" --job-file ~/.local/state/omarchy-feedback/issues/<id>/FEEDBACK.md
```

then opens the Singularix dashboard on the Rix tab. Rix is recorded as the
worker's parent, so the job shows up in his tasks. The backend is the one Rix
runs on (or its default backend). When Singularix is missing there is no Rix
hand-off: the bar panel and the viewer show a green "Get Rix: free upgrade"
button in its place, with the pitch under it in the viewer (its tooltip in the
panel). `omarchy-feedback get-singularix` prints the same pitch and where to get it. When Rix is not set up (`omarchy-agent-launcher rix setup`),
the button is dimmed and says so. Read the result with the command stored on
the hand-off (`omarchy-agent-launcher result feedback-…`), shown in the viewer.

Right after the hand-off Feedback reads the worker's first output. A worker that
cannot start (its runtime is missing, say) is stopped and reported as a failed
hand-off, instead of sitting in Singularix as "running".

### What the launched programs see

Feedback runs its own tools with a PATH limited to root-owned folders. What a
hand-off starts for you (your coding agent, Rix's launcher and its workers) gets
your desktop session's PATH instead, the same one Omarchy's own agent key uses,
so tools installed with mise or into `~/.local/bin` are found. The program
Feedback starts is still resolved by absolute path; `--dry-run` prints the PATH
the child will get.

## Your coding agent

```
omarchy-feedback handoff agent <id> [--agent <name>]
```

opens a coding agent (Claude Code, Codex, Grok, OpenCode, …) with Omarchy's own
flags for it, in a terminal that changes into the right folder first. The panel
and the viewer offer the agents that are installed, Omarchy's default
(`omarchy default agent <name>`) first; with one installed, the button goes
straight to it. Installed means the command runs without installing anything:
Omarchy keeps a lazy mise shim for every agent it knows, so for those mise is
asked whether the tool is really there.

A picked agent other than the default starts through `omarchy-agent` like the
default does: the agent's terminal answers `omarchy-default-agent` with the pick
for that launch, so your default is left alone.

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
  --subject plugin:fans.omarchy.singularix --description "…"
omarchy-feedback list --json
omarchy-feedback show <id> --json
omarchy-feedback set <id> notes "Root cause: …"
```
