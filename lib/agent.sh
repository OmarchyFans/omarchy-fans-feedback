#!/bin/bash
# Agent runners for `author repair`. Each gets a worktree and a prompt file and
# must leave its changes in the worktree (committed or not). The agent is
# chosen with --agent, or config.json { "agent": "claude" }. Custom commands go
# in config.json { "agents": { "<name>": "shell command" } } and receive
# BF_WORKDIR and BF_PROMPT in the environment.
#
# The report text inside the prompt is untrusted end-user input; the prompt
# template says so, and the agent's write access is limited to the worktree.

agent_run() { # agent_run <name> <workdir> <prompt-file>
  local name=$1 wt=$2 prompt=$3 custom
  custom=$(config_get ".agents[\"$name\"]" "")
  if [[ -n $custom ]]; then
    (cd "$wt" && BF_WORKDIR=$wt BF_PROMPT=$prompt run bash -c "$custom"); return $?
  fi
  case "$name" in
    claude)
      have claude || fail "claude not found (install Claude Code, or pick --agent hermes)"
      (cd "$wt" && run claude -p --permission-mode acceptEdits --output-format text \
         --allowedTools "Read,Edit,Write,Grep,Glob,Bash(git *),Bash(bash tests/*),Bash(./tests/*),Bash(jq *),Bash(shellcheck *)" \
         --add-dir "$wt" <"$prompt") ;;
    hermes)
      have hermes || fail "hermes not found (see docs/hermes.md)"
      (cd "$wt" && run hermes chat --oneshot --yolo -Q --query-file "$prompt" --in "$wt") ;;
    codex)
      have codex || fail "codex not found"
      (cd "$wt" && run codex exec --full-auto "$(cat "$prompt")") ;;
    *) fail "unknown agent '$name' (claude|hermes|codex, or define agents.$name in $BF_CONFIG)" ;;
  esac
}
