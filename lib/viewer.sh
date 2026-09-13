#!/bin/bash
# The web viewer (served by the daemon) and exports.
#   open [id]                             open the viewer as an app window (token in the URL fragment)
#   export <id> [--md|--pdf] [--out FILE] write the Markdown or PDF summary

cmd_open() {
  local id=${1:-}
  [[ -z $id ]] || valid_issue_id "$id" || fail "open [issue id]"
  cmd_daemon ensure >/dev/null || fail "the recorder (which serves the viewer) is not running"
  local i; for ((i = 0; i < 30; i++)); do [[ -s $OF_RUNTIME/viewer.json ]] && break; sleep 0.1; done
  [[ -s $OF_RUNTIME/viewer.json ]] || fail "the viewer did not start; see $OF_RUNTIME/daemon.log"
  local url; url=$(py of_viewer.py url $id) || fail "no viewer URL"
  if [[ $(jq -r .fallback "$OF_RUNTIME/viewer.json") == true ]]; then
    warn "port 7741 on 127.79.33.1 was busy; the viewer runs on a temporary port this session (an installed Feedback app will not reach it)"
  fi
  if have omarchy-launch-webapp; then omarchy-launch-webapp "$url" >/dev/null 2>&1 &
  else xdg-open "$url" >/dev/null 2>&1 & fi
  (( JSON )) && jq -cn --arg u "${url%%#*}" '{ok:true, url:$u}' || say "Opened the viewer${id:+ on #$id}."
}

cmd_export() {
  local id=${1:-} fmt=md out=""; shift || true
  valid_issue_id "$id" || fail "export <id> [--md|--pdf] [--out FILE]"
  while (($#)); do case "$1" in --md) fmt=md ;; --pdf) fmt=pdf ;; --out) out=$2; shift ;; *) fail "export: unknown option $1" ;; esac; shift; done
  py of_db.py get "$id" >/dev/null 2>&1 || fail "no issue #$id"
  [[ -n $out ]] || out="$PWD/feedback-$id.$fmt"
  if [[ $fmt == md ]]; then
    py of_report.py summary "$id" >"$out" || fail "could not write $out"
  else
    local r; r=$(py of_viewer.py pdf "$id" "$out") || fail "PDF export failed: $(jq -r .error <<<"$r" 2>/dev/null)"
  fi
  (( JSON )) && jq -cn --arg p "$out" '{ok:true, path:$p}' || say "Wrote $out"
}
