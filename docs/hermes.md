# Processing the inbox with a Hermes agent

Claude Code is the default repair agent (`claude -p`, signed in through the
browser or `ANTHROPIC_API_KEY`). Hermes Agent works the same way and can also
run the whole triage conversation for you.

## 1. Install the skill

```
mkdir -p ~/.hermes/skills/devops
cp -r ~/.config/omarchy/plugins/fans.omarchy.beta-feedback/skills/beta-feedback ~/.hermes/skills/devops/
```

(Or point Agent Launcher at it: the skill shows up in its Skills checklist as
`devops/beta-feedback`.)

## 2. Make Hermes the repair agent

`~/.config/omarchy-beta-feedback/config.json`:

```json
{ "agent": "hermes" }
```

`author repair` then runs, inside the fix worktree:

```
hermes chat --oneshot --yolo -Q --query-file <prompt> --in <worktree>
```

Any other agent: `{ "agents": { "mytool": "mytool --auto \"$BF_PROMPT\"" } }`
and `--agent mytool`. The command runs in the worktree with `BF_WORKDIR` and
`BF_PROMPT` set.

## 3. Let a Hermes session work the list

From Agent Launcher (SUPER + ALT + A): agent *Hermes*, runtime *local*, tick
the `devops/beta-feedback` skill, and give it this job:

> Work my beta-feedback inbox. Show me the queue, assess each new report, and
> wait for my approve/reject/repair/promote decisions before running them.

Or from a terminal:

```
hermes chat -s beta-feedback -q "Show me my beta-feedback inbox and assess the new reports."
```

The skill forbids approving, merging or promoting without your say-so; the
CLI enforces the rest (fixes only ever land on `staging`, promotion to `main`
is a separate command).
