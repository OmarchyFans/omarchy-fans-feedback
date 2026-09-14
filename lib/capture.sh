#!/bin/bash
# Capturing an issue. Order matters: nothing of ours appears on screen until
# the screenshot is taken.
#
#   capture [--source key|chip|panel|cli] [--minutes N]
#           [--no-form --title T [--kind bug|feature] [--subject auto|omarchy|app|plugin:<id>] [--description D]]
#           [--no-annotate]
#   capture-form <pending-dir>     (runs in a floating terminal: annotate, then the form)

wait_panel_closed() { # the issue list's "Report an issue" button closes the panel first
  local i
  for ((i = 0; i < 20; i++)); do
    hyprctl -j layers 2>/dev/null | jq -e '[.. | objects | select(has("namespace")) | .namespace] | index("omarchy-keyboard-panel") | not' >/dev/null && break
    sleep 0.075
  done
  sleep 0.15   # let the close animation finish
}

env_json() {
  local omarchy hypr qs theme kernel monitors
  omarchy=$(pacman -Q omarchy 2>/dev/null | awk '{print $2}')
  [[ -z $omarchy && -f /usr/share/omarchy/version ]] && omarchy=$(cat /usr/share/omarchy/version 2>/dev/null)
  hypr=$(hyprctl version -j 2>/dev/null | jq -r '.tag // .version // empty' 2>/dev/null)
  qs=$(pacman -Q quickshell 2>/dev/null | awk '{print $2}')
  theme=$(basename "$(readlink -f "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/current/theme" 2>/dev/null)" 2>/dev/null)
  kernel=$(uname -r)
  monitors=$(hyprctl -j monitors 2>/dev/null | jq -c '[.[] | {name, width, height, scale, x, y, focused}]' 2>/dev/null)
  jq -cn --arg omarchy "$omarchy" --arg hypr "$hypr" --arg qs "$qs" --arg theme "$theme" --arg kernel "$kernel" \
     --argjson monitors "${monitors:-[]}" \
     '{omarchy:$omarchy, hyprland:$hypr, quickshell:$qs, theme:$theme, kernel:$kernel, monitors:$monitors}'
}

pending_dir_ok() { # a pending capture folder of ours, not an arbitrary path
  local p; p=$(readlink -f -- "$1" 2>/dev/null) || return 1
  [[ -d $p && $(dirname "$p") == "$(readlink -f -- "$OF_ISSUES")" && $(basename "$p") == .pending-* ]]
}

cmd_capture() {
  local source=cli minutes=10 noform=0 noannotate=0 title="" kind="bug" subject="auto" desc=""
  while (($#)); do
    case "$1" in
      --source) source=$2; shift ;; --minutes) minutes=$2; shift ;;
      --no-form) noform=1 ;; --no-annotate) noannotate=1 ;;
      --title) title=$2; shift ;; --kind) kind=$2; shift ;; --subject) subject=$2; shift ;;
      --description) desc=$2; shift ;;
      *) fail "capture: unknown option $1" ;;
    esac; shift
  done
  [[ $minutes =~ ^[0-9]+$ ]] && (( minutes >= 1 && minutes <= 12 )) || fail "--minutes must be 1-12"
  [[ $kind == bug || $kind == feature ]] || fail "--kind must be bug or feature"
  (( noform )) && [[ -z $title ]] && fail "--no-form needs --title"
  ensure_state
  cmd_daemon ensure >/dev/null 2>&1 || warn "event recorder is not running; the report will have no event log"
  [[ $source == panel ]] && wait_panel_closed

  local t P mon
  t=$(now_ms)
  P="$OF_ISSUES/.pending-$t-$RANDOM"
  mkdir -m 700 "$P" || fail "cannot create $P"

  # 1. What is on screen, before anything of ours is.
  hyprctl -j activewindow >"$P/activewindow.json" 2>/dev/null || printf '{}' >"$P/activewindow.json"
  hyprctl -j monitors >"$P/monitors.json" 2>/dev/null || printf '[]' >"$P/monitors.json"
  hyprctl -j cursorpos >"$P/cursor.json" 2>/dev/null || printf '{}' >"$P/cursor.json"
  mon=$(jq -r '(map(select(.focused)) + .)[0].name // empty' "$P/monitors.json" 2>/dev/null)
  if have grim; then
    if [[ -n $mon ]]; then grim -o "$mon" "$P/shot.png" 2>/dev/null || grim "$P/shot.png" 2>/dev/null
    else grim "$P/shot.png" 2>/dev/null; fi
  fi
  [[ -s $P/shot.png ]] || warn "no screenshot (grim failed)"

  # 2. The focused window, cropped from the monitor shot (window coordinates are logical).
  if [[ -s $P/shot.png ]] && have ffmpeg; then
    local crop
    crop=$(jq -rn --slurpfile w "$P/activewindow.json" --slurpfile m "$P/monitors.json" --arg mon "$mon" '
      ($w[0] // {}) as $w | (($m[0] // []) | map(select(.name == $mon)) | .[0]) as $m
      | if ($w.at and $w.size and $m) then
          ($m.scale // 1) as $s
          | [ (($w.size[0]) * $s | floor), (($w.size[1]) * $s | floor),
              ((($w.at[0] - $m.x) * $s) | floor), ((($w.at[1] - $m.y) * $s) | floor) ]
          | map(if . < 0 then 0 else . end)
          | select(.[0] > 16 and .[1] > 16)
          | "\(.[0]):\(.[1]):\(.[2]):\(.[3])"
        else empty end' 2>/dev/null)
    [[ -n $crop ]] && ffmpeg -loglevel error -y -i "$P/shot.png" -vf "crop=$crop" "$P/window.png" 2>/dev/null
  fi

  # 3. The event log leading up to now, and the replay buffer when armed.
  py ofctl.py snap "$P/events.jsonl" "$minutes" >"$P/snap.json" 2>/dev/null || printf '{}' >"$P/snap.json"
  if [[ $(py ofctl.py status 2>/dev/null | jq -r '.replay.armed // false') == true ]]; then
    : >"$P/replay.pending"
    ( py ofctl.py save-replay "$P/replay.mp4" >"$P/replay.json" 2>&1; rm -f "$P/replay.pending" ) &
  fi

  env_json >"$P/env.json" 2>/dev/null || printf '{}' >"$P/env.json"
  jq -n --argjson t "$t" --arg source "$source" --arg mon "$mon" \
     --slurpfile w "$P/activewindow.json" --slurpfile c "$P/cursor.json" --slurpfile e "$P/env.json" \
     --arg title "$title" --arg kind "$kind" --arg desc "$desc" \
     '{captureMs:$t, source:$source, monitor:$mon, title:$title, kind:$kind, description:$desc,
       context:{activewindow:(($w[0] // {}) | {class, title, pid, at, size, workspace:(.workspace.name // null)}),
                cursor:($c[0] // {}), env:($e[0] // {})}}' >"$P/meta.json"

  if (( noform )); then
    capture_set_subject "$P" "$subject" || { rm -rf "$P"; fail "unknown subject '$subject'"; }
    capture_finish "$P"
    return
  fi
  if [[ -z ${OF_POPUP:-} && ! -t 0 ]]; then
    # Started from a keybinding or the bar: the form needs a terminal.
    have omarchy-launch-tui || { warn "omarchy-launch-tui not found; saving as untitled"; capture_untitled "$P"; return; }
    omarchy-launch-tui --app-id=TUI.float env OF_POPUP=1 OF_NO_ANNOTATE="$noannotate" "$OF_SELF" capture-form "$P"
    return 0
  fi
  OF_NO_ANNOTATE=$noannotate cmd_capture_form "$P"
}

capture_set_subject() { # capture_set_subject <P> auto|omarchy|app|plugin:<id>|<json>
  local P=$1 spec=$2 subj
  case "$spec" in
    auto)     subj=$(py of_subject.py candidates "$P" | jq -c '.[0]') ;;
    omarchy)  subj=$(py of_subject.py candidates "$P" | jq -c 'map(select(.type == "omarchy"))[0]') ;;
    app)      subj=$(py of_subject.py candidates "$P" | jq -c 'map(select(.type == "app"))[0] // empty') ;;
    plugin:*) valid_plugin_id "${spec#plugin:}" || return 1; subj=$(py of_subject.py plugin "${spec#plugin:}") ;;
    \{*)      subj=$(jq -c . <<<"$spec") ;;
    *)        return 1 ;;
  esac
  [[ -n $subj && $subj != null ]] || return 1
  jq --argjson s "$subj" '.subject = $s' "$P/meta.json" >"$P/meta.json.tmp" && mv "$P/meta.json.tmp" "$P/meta.json"
}

capture_wait_replay() {
  local P=$1 i
  [[ -e $P/replay.pending ]] || return 0
  say "Saving the screen replay…"
  for ((i = 0; i < 600; i++)); do [[ -e $P/replay.pending ]] || break; sleep 0.1; done
  [[ -s $P/replay.mp4 ]] || warn "the replay could not be saved: $(jq -r '.error // empty' "$P/replay.json" 2>/dev/null)"
}

capture_finish() { # capture_finish <P>: into the database, summary, notification
  local P=$1 out id title
  capture_wait_replay "$P"
  out=$(py of_db.py create "$P") || fail "could not save the issue (the capture is kept in $P)"
  id=$(jq -r .id <<<"$out")
  py of_report.py summary "$id" >"$OF_ISSUES/$id/summary.md" && py of_db.py attach "$id" summary summary.md >/dev/null
  title=$(jq -r .title "$OF_ISSUES/$id/meta.json")
  notify "Feedback #$id saved" "$title" --exec "$OF_SELF" open "$id"
  # Look for secrets the text rules cannot see (screenshots, the replay) and warn about any found.
  if [[ ${OF_SCAN_SYNC:-0} == 1 ]]; then py of_secrets.py scan "$id" >/dev/null || true
  else setsid -f nice -n 19 env PYTHONDONTWRITEBYTECODE=1 python3 "$OF_LIB/of_secrets.py" scan "$id" >/dev/null 2>&1 </dev/null; fi
  if (( JSON )); then jq -c . <<<"$out"; else say "Saved issue #$id: $title"; fi
}

capture_untitled() {
  local P=$1
  jq '.title = (if .title == "" then "Untitled feedback" else .title end)' "$P/meta.json" >"$P/meta.json.tmp" && mv "$P/meta.json.tmp" "$P/meta.json"
  capture_set_subject "$P" auto || true
  capture_finish "$P"
}

cmd_capture_form() {
  local P=${1:-}
  pending_dir_ok "$P" || fail "capture-form: not a pending capture folder"
  P=$(readlink -f -- "$P")
  if [[ ${OF_POPUP:-} == 1 ]]; then
    fail() { warn "$*"; read -rp "Press Enter to close…" _; exit 1; }
  fi

  if [[ -s $P/shot.png && ${OF_NO_ANNOTATE:-0} != 1 ]] && have tensaku; then
    say "Mark up the screenshot: draw, add arrows and text. Enter saves, Escape skips."
    tensaku -f "$P/shot.png" -o "$P/annotated.png" --actions-on-enter save-to-file,exit --actions-on-escape exit \
      --early-exit --initial-tool arrow --disable-notifications >/dev/null 2>&1 || true
  fi

  ui_style "Feedback"
  local cands labels choice subj kind title desc
  cands=$(py of_subject.py candidates "$P")
  mapfile -t labels < <(jq -r '.[].label' <<<"$cands")
  if choice=$(ui_filter "What is this about?" "${labels[@]}"); then
    subj=$(jq -c --arg l "$choice" 'map(select(.label == $l))[0] // .[0]' <<<"$cands")
  else
    capture_cancelled "$P"; return
  fi
  kind=$(ui_choose "Bug or feature request?" bug feature) || { capture_cancelled "$P"; return; }
  title=$(ui_input "One-line title" "e.g. The launcher ignores my second click") || { capture_cancelled "$P"; return; }
  [[ -n ${title// /} ]] || title="Untitled feedback"
  desc=$(ui_write "What happened, what you expected (Ctrl+D when done, Esc to skip)" "Steps, expectation, actual result") || desc=""
  jq --argjson s "$subj" --arg k "$kind" --arg t "$title" --arg d "$desc" \
     '.subject = $s | .kind = $k | .title = $t | .description = $d' "$P/meta.json" >"$P/meta.json.tmp" \
     && mv "$P/meta.json.tmp" "$P/meta.json"
  capture_finish "$P"
  [[ ${OF_POPUP:-} == 1 ]] && sleep 1.2
  return 0
}

capture_cancelled() {
  local P=$1
  if ui_confirm "Discard this capture?"; then
    capture_wait_replay "$P" >/dev/null 2>&1
    rm -rf "$P"; say "Discarded."
  else
    capture_untitled "$P"
  fi
}

# Pending captures older than a day were abandoned (a crashed form): clean up.
prune_pending() {
  find "$OF_ISSUES" -maxdepth 1 -name '.pending-*' -type d -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
}
