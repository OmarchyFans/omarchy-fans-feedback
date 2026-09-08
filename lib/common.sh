#!/bin/bash
# Shared helpers for omarchy-beta-feedback. Plain bash + jq + gum; nothing is
# downloaded or executed from the network by this file.

BF_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-beta-feedback"
BF_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-beta-feedback"
BF_PLUGINS="${BF_PLUGINS_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins}"
BF_ENROLL="$BF_STATE/enrollments.json"   # {pluginId: {...}}
BF_REPORTS="$BF_STATE/reports.jsonl"     # one line per submitted report
BF_SHOTS="$BF_STATE/shots"               # raw grabs written by the SDK (never inside a plugin dir)
BF_BUNDLES="$BF_STATE/bundles"           # <ts>-<pluginId>/ report bundles
BF_CONFIG="$BF_CONF/config.json"
BF_DRY_RUN=${BF_DRY_RUN:-0}
BF_BETA_DAYS=${BF_BETA_DAYS:-5}          # enrollment lasts this many days of use
BF_LABEL=beta-feedback

# ---------------------------------------------------------------- output ----
say()  { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf 'beta-feedback: %s\n' "$*" >&2; }
fail() { warn "$*"; exit 1; }
hr()   { printf '\n'; }
have() { command -v "$1" >/dev/null 2>&1; }

run() {
  if (( BF_DRY_RUN )); then
    printf '[dry-run] %q' "$1"; printf ' %q' "${@:2}"; printf '\n'
    return 0
  fi
  "$@"
}

# Today's date; tests pin it with BF_NOW=YYYY-MM-DD.
today() { printf '%s' "${BF_NOW:-$(date +%F)}"; }
now_iso() { if [[ -n ${BF_NOW:-} ]]; then printf '%sT00:00:00Z' "$BF_NOW"; else date -u +%FT%TZ; fi; }
# Bundle ids: timestamp plus a random suffix, so two reports in one second never collide.
ts_id() {
  local d; if [[ -n ${BF_NOW:-} ]]; then d="${BF_NOW//-/}-000000"; else d=$(date +%Y%m%d-%H%M%S); fi
  printf '%s-%s' "$d" "$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
}

# Same rule omarchy-plugin-update applies to ids.
valid_plugin_id() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $1 != *..* ]]; }
require_plugin_id() { valid_plugin_id "${1:-}" || fail "invalid plugin id '${1:-}'"; }
plugin_dir() { printf '%s/%s' "$BF_PLUGINS" "$1"; }

ensure_state() { mkdir -p "$BF_STATE" "$BF_SHOTS" "$BF_BUNDLES" "$BF_CONF"; }

# Atomic JSON write: json_write <path> <json-text>
json_write() {
  local path=$1 tmp
  mkdir -p "$(dirname "$path")"
  tmp=$(mktemp "$(dirname "$path")/.tmp.XXXXXX")
  printf '%s\n' "$2" >"$tmp" && mv -f "$tmp" "$path"
}
json_file_or() { if [[ -s $1 ]]; then cat "$1"; else printf '%s' "$2"; fi; }

# config.json accessors (author-side settings and the agent command)
config_get() { # config_get <jq-path> <default>
  local v
  v=$(json_file_or "$BF_CONFIG" '{}' | jq -r --arg d "$2" "$1 // \$d" 2>/dev/null) || v=$2
  printf '%s' "$v"
}

# ---------------------------------------------------------------- gum UI ----
# Every interactive prompt goes through these so tests can script answers
# (BF_UI_STUBS sources a file that redefines them).
ui_choose()  { gum choose --header "$1" "${@:2}"; }
ui_input()   { gum input --header "$1" --placeholder "${2:-}" --value "${3:-}"; }
ui_write()   { gum write --header "$1" --placeholder "${2:-}" --height 8; }
ui_confirm() { gum confirm "$1"; }
ui_style()   { gum style --border rounded --padding "0 1" "$@"; }
ui_pager()   { gum pager <"$1"; }

# Re-open this CLI in a floating Omarchy terminal (the SDK launches us detached).
popup_reexec() { # popup_reexec <args...>
  have omarchy-launch-tui || fail "--popup needs Omarchy (omarchy-launch-tui not found)"
  exec omarchy-launch-tui --app-id=TUI.float env BF_POPUP=1 "$BF_SELF" "$@"
}

notify() { # notify <headline> [body] [--exec prog args...]
  if have omarchy-notification-send; then
    omarchy-notification-send --app-name "Beta feedback" -g 󰃤 "$@" >/dev/null 2>&1 || true
  else
    printf 'notify: %s\n' "$*" >&2
  fi
}

strip_ansi() { sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g'; }
urlencode() { jq -rn --arg s "$1" '$s|@uri'; }
