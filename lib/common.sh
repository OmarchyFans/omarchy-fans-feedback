#!/bin/bash
# Shared helpers for omarchy-feedback. Plain bash + jq + gum + python3; nothing
# is downloaded or executed from the network by this file.

OF_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-feedback"
OF_STATE="${OF_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-feedback}"
OF_RUNTIME="${OF_RUNTIME:-${XDG_RUNTIME_DIR:-/tmp}/omarchy-feedback}"
OF_PLUGINS="${OF_PLUGINS_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins}"
OF_ISSUES="$OF_STATE/issues"
OF_DB="$OF_STATE/feedback.db"
OF_CONFIG="$OF_CONF/config.json"
OF_DRY_RUN=${OF_DRY_RUN:-0}
export OF_STATE OF_RUNTIME PYTHONDONTWRITEBYTECODE=1   # no __pycache__ inside the plugin folder

# ---------------------------------------------------------------- output ----
say()  { if (( ${JSON:-0} )); then printf '%s\n' "$*" >&2; else printf '%s\n' "$*"; fi; }
info() { printf '  %s\n' "$*"; }
warn() { printf 'omarchy-feedback: %s\n' "$*" >&2; }
fail() { warn "$*"; exit 1; }
hr()   { printf '\n'; }
have() { command -v "$1" >/dev/null 2>&1; }

run() {
  if (( OF_DRY_RUN )); then
    printf '[dry-run] %q' "$1"; printf ' %q' "${@:2}"; printf '\n'
    return 0
  fi
  "$@"
}

now_ms() { if [[ -n ${OF_NOW_MS:-} ]]; then printf '%s' "$OF_NOW_MS"; else date +%s%3N; fi; }
now_iso() { date -u +%FT%TZ; }

# Same rule omarchy-plugin-update applies to ids.
valid_plugin_id() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $1 != *..* ]]; }
valid_issue_id() { [[ $1 =~ ^[0-9]+$ ]]; }
plugin_dir() { printf '%s/%s' "$OF_PLUGINS" "$1"; }

ensure_state() { mkdir -p "$OF_STATE" "$OF_ISSUES" "$OF_CONF"; chmod 700 "$OF_STATE" 2>/dev/null || true; }

json_file_or() { if [[ -s $1 ]]; then cat "$1"; else printf '%s' "$2"; fi; }
config_get() { # config_get <jq-path> <default>
  local v
  v=$(json_file_or "$OF_CONFIG" '{}' | jq -r --arg d "$2" "$1 // \$d" 2>/dev/null) || v=$2
  printf '%s' "$v"
}

py() { python3 "$OF_LIB/$1" "${@:2}"; }

# ---------------------------------------------------------------- gum UI ----
# Every interactive prompt goes through these so tests can script answers
# (OF_UI_STUBS sources a file that redefines them).
ui_choose()  { gum choose --header "$1" "${@:2}"; }
ui_filter()  { gum filter --header "$1" --placeholder "type to filter" "${@:2}"; }
ui_input()   { gum input --header "$1" --placeholder "${2:-}" --value "${3:-}"; }
ui_write()   { gum write --header "$1" --placeholder "${2:-}" --height 8; }
ui_confirm() { gum confirm "$1"; }
ui_style()   { gum style --border rounded --padding "0 1" "$@" >&2; }

notify() { # notify <headline> [body] [--exec prog args...]
  if have omarchy-notification-send; then
    omarchy-notification-send --app-name "Feedback" -g 󰃤 "$@" >/dev/null 2>&1 || true
  else
    printf 'notify: %s\n' "$*" >&2
  fi
}

strip_ansi() { LC_ALL=C sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g'; }
urlencode() { jq -rn --arg s "$1" '$s|@uri'; }
