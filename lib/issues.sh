#!/bin/bash
# The local issue list: list, show, change, delete; and the replay toggle.

require_issue() { valid_issue_id "${1:-}" || fail "issue id must be a number"; }

cmd_list() { # list [--status open|all|<status>]
  local status=open
  while (($#)); do case "$1" in --status) status=$2; shift ;; --all) status=all ;; *) fail "list: unknown option $1" ;; esac; shift; done
  ensure_state; prune_pending
  local rows; rows=$(py of_db.py list --status "$status") || fail "could not read the issue database"
  if (( JSON )); then printf '%s\n' "$rows"; return; fi
  if [[ $(jq length <<<"$rows") == 0 ]]; then say "No ${status/all/} issues."; return; fi
  jq -r '.[] | "#\(.id)\t\(.status)\t\(.kind)\t\(.subject_name // .subject_id // "?")\t\(.title)"' <<<"$rows" | column -t -s $'\t'
}

cmd_show() { # show <id>
  require_issue "${1:-}"
  if (( JSON )); then py of_db.py get "$1"; else py of_report.py summary "$1"; fi
}

cmd_set() { # set <id> status|notes|title|description|kind <value>
  require_issue "${1:-}"; [[ -n ${2:-} ]] || fail "set <id> <field> <value>"
  OF_BY=${OF_BY:-cli} py of_db.py set "$1" "$2" "${3-}" >/dev/null || exit 1
  py of_report.py summary "$1" >"$OF_ISSUES/$1/summary.md" 2>/dev/null || true
  (( JSON )) && py of_db.py get "$1" || say "#$1: $2 updated"
}

cmd_delete() { # delete <id>
  require_issue "${1:-}"
  local n; n=$(py of_db.py delete "$1" | jq -r .deleted)
  [[ $n == 1 ]] || fail "no issue #$1"
  say "Deleted #$1."
}

cmd_arm() { # arm [seconds]
  cmd_daemon ensure >/dev/null || fail "the recorder is not running"
  local out; out=$(py ofctl.py arm "${1:-120}") || fail "could not arm the replay: $(jq -r '.error // "unknown error"' <<<"$out" 2>/dev/null)"
  if (( JSON )); then printf '%s\n' "$out"; else say "Screen replay armed on $(jq -r .monitor <<<"$out"): the last $(jq -r .seconds <<<"$out") s are kept in memory."; fi
}

cmd_disarm() {
  local out; out=$(py ofctl.py disarm) || fail "the recorder is not running"
  if (( JSON )); then printf '%s\n' "$out"; else say "Screen replay off."; fi
}
