#!/bin/bash
# Troubleshooting recording: a video of the focused screen (Omarchy's own
# recorder) plus a timestamped log of key presses and desktop events, saved as
# a report bundle. The key log comes from lib/keylog.py; its header explains how
# keys are captured and what is hidden.
#
#   record start [--plugin ID] [--all-keys] [--no-overlay]
#   record stop [--no-report] [--auto]
#   record status [--json]

BF_REC_RUN="${BF_REC_RUNTIME:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/omarchy-beta-feedback}"
BF_REC_SESSION="$BF_REC_RUN/recording.json"
BF_REC_RECORDER_FILE="${BF_REC_RECORDER_FILE:-/tmp/omarchy-screenrecord-filename}"
BF_REC_MAX_SECONDS=${BF_REC_MAX_SECONDS:-1200}

cmd_record() {
  local sub=${1:-status}; shift || true
  case "$sub" in
    start)  record_start "$@" ;;
    stop)   record_stop "$@" ;;
    status) record_status "$@" ;;
    *) fail "unknown record command '$sub' (start|stop|status)" ;;
  esac
}

rec_ms() { date +%s%3N; }
rec_screen_recording() { pgrep -f '^gpu-screen-recorder' >/dev/null 2>&1; }
rec_helper_alive() { # rec_helper_alive <pid>
  [[ ${1:-} =~ ^[0-9]+$ ]] && kill -0 "$1" 2>/dev/null && grep -qa 'keylog.py' "/proc/$1/cmdline" 2>/dev/null
}

# Keyboard layout and input method: the usual suspects when keys misbehave.
input_json() {
  local kb ime=none
  kb=$(hyprctl devices -j 2>/dev/null | jq -c '[.keyboards[]? | select(.main)] | (.[0] // {}) | {name, layout, variant, options}' 2>/dev/null)
  [[ -n $kb ]] || kb='{}'
  if pgrep -x fcitx5 >/dev/null 2>&1; then
    ime="fcitx5 $(pacman -Q fcitx5 2>/dev/null | cut -d' ' -f2)"
  elif pgrep -x ibus-daemon >/dev/null 2>&1; then
    ime=ibus
  fi
  jq -cn --argjson kb "$kb" --arg ime "${ime% }" '{keyboard: $kb, inputMethod: $ime}'
}

record_start() {
  local plugin="" all=false overlay=true
  while (($#)); do
    case "$1" in
      --plugin) plugin=${2:-}; shift ;;
      --all-keys) all=true ;;
      --no-overlay) overlay=false ;;
      *) fail "record start: unknown option $1" ;;
    esac; shift
  done
  if [[ -n $plugin ]]; then
    require_plugin_id "$plugin"
    [[ -d $(plugin_dir "$plugin") ]] || fail "plugin '$plugin' is not installed"
  fi
  have hyprctl || fail "a troubleshooting recording needs Hyprland (hyprctl not found)"
  have python3 || fail "a troubleshooting recording needs python3"
  umask 077
  ensure_state; mkdir -p "$BF_REC_RUN"
  if [[ -s $BF_REC_SESSION ]]; then
    rec_helper_alive "$(jq -r '.pid // ""' "$BF_REC_SESSION")" \
      && fail "a troubleshooting recording is already running (omarchy-beta-feedback record stop)"
    rm -f "$BF_REC_SESSION"
  fi
  rec_screen_recording && fail "a screen recording is already running; stop it first (Alt+Print)"

  local b; b="$BF_BUNDLES/$(ts_id)-${plugin:-desktop}-recording"
  mkdir -p "$b"
  hyprctl binds -j >"$b/binds.json" 2>/dev/null || printf '[]' >"$b/binds.json"
  env_json "$plugin" >"$b/env.json"
  input_json >"$b/input.json"

  local started video="" vstart i
  started=$(rec_ms)
  # Output must not be captured: the recorder leaves gpu-screen-recorder running
  # with our stdout, and a pipe would never close.
  omarchy capture screenrecording --fullscreen >/dev/null 2>&1 </dev/null
  for ((i = 0; i < 50; i++)); do
    if [[ -s $BF_REC_RECORDER_FILE ]]; then video=$(<"$BF_REC_RECORDER_FILE"); break; fi
    sleep 0.1
  done
  if [[ -z $video ]]; then
    rm -rf "$b"
    fail "the screen recorder did not start (try: omarchy capture screenrecording --fullscreen)"
  fi
  vstart=$(rec_ms)

  # --fullscreen records the focused monitor; the on-screen keys belong there.
  local monitor; monitor=$(hyprctl monitors -j 2>/dev/null | jq -r 'first(.[]? | select(.focused == true)) | .name // empty' 2>/dev/null)
  local args=(run --bundle "$b" --runtime "$BF_REC_RUN" --cli "$BF_SELF" --max "$BF_REC_MAX_SECONDS" --monitor "$monitor")
  [[ $all == true ]] && args+=(--all-keys)
  [[ $overlay == true ]] && args+=(--show-keys)
  setsid python3 "$BF_LIB/keylog.py" "${args[@]}" >>"$b/helper.log" 2>&1 </dev/null &
  local pid=$!

  json_write "$BF_REC_SESSION" "$(jq -cn --arg b "$b" --argjson pid "$pid" --arg v "$video" --argjson s "$started" \
    --argjson vs "$vstart" --arg p "$plugin" --argjson all "$all" --argjson ov "$overlay" \
    '{bundle: $b, pid: $pid, video: $v, startedAt: $s, videoStartedAt: $vs, plugin: $p, allKeys: $all, overlay: $ov}')"
  cp -f "$BF_REC_SESSION" "$b/session.json"
  say "Troubleshooting recording started: $b"
  local what="letters and digits hidden"; [[ $all == true ]] && what="every key, letters included"
  notify "Troubleshooting recording started" "Recording the focused screen and your key presses ($what). Stop it from the 󰃤 bar chip."
}

record_stop() {
  local report=1 auto=0
  while (($#)); do
    case "$1" in
      --no-report) report=0 ;;
      --auto) auto=1; report=0 ;;
      *) fail "record stop: unknown option $1" ;;
    esac; shift
  done
  [[ -s $BF_REC_SESSION ]] || fail "no troubleshooting recording is running"
  local s b pid video plugin i
  s=$(cat "$BF_REC_SESSION")
  b=$(jq -r '.bundle // ""' <<<"$s"); pid=$(jq -r '.pid // ""' <<<"$s")
  video=$(jq -r '.video // ""' <<<"$s"); plugin=$(jq -r '.plugin // ""' <<<"$s")
  if [[ ! -d $b || $b != "$BF_BUNDLES"/* ]]; then
    rm -f "$BF_REC_SESSION"
    fail "the recording session did not point at a bundle; cleared it"
  fi

  if rec_helper_alive "$pid"; then
    kill -TERM "$pid" 2>/dev/null
    for ((i = 0; i < 30; i++)); do rec_helper_alive "$pid" || break; sleep 0.1; done
    rec_helper_alive "$pid" && kill -KILL "$pid" 2>/dev/null
  fi
  # Never leave the Lua listener behind, even if the helper died.
  have hyprctl && hyprctl eval "$(python3 "$BF_LIB/keylog.py" lua disarm)" >/dev/null 2>&1
  rm -f "$BF_REC_RUN/keys.raw" "$BF_REC_RUN/overlay.json"

  if rec_screen_recording && [[ -n $video && $(cat "$BF_REC_RECORDER_FILE" 2>/dev/null) == "$video" ]]; then
    say "Stopping the screen recording (Omarchy finishes the video)…"
    omarchy capture screenrecording --stop-recording >"$b/recorder.log" 2>&1 </dev/null
  fi

  rm -f "$BF_REC_SESSION"
  local saved=false; [[ -n $video && -f $video ]] && saved=true
  jq -c --argjson t "$(rec_ms)" --argjson saved "$saved" '.stoppedAt = $t | .videoSaved = $saved' <<<"$s" >"$b/session.json"
  python3 "$BF_LIB/keylog.py" render --bundle "$b" >/dev/null 2>>"$b/helper.log" || warn "could not render the timeline"
  say "Saved the troubleshooting recording in $b"

  if (( auto )); then
    notify "Troubleshooting recording stopped after $((BF_REC_MAX_SECONDS / 60)) min" "Click to write a report from it" \
      --exec "$BF_SELF" report --bundle "$b" ${plugin:+--plugin "$plugin"}
  elif (( report )); then
    cmd_report --bundle "$b" ${plugin:+--plugin "$plugin"}
  else
    notify "Troubleshooting recording saved" "Click to open the folder" --exec xdg-open "$b"
  fi
}

record_status() {
  local s=null alive=false secs=0 video=false
  if [[ -s $BF_REC_SESSION ]]; then
    s=$(cat "$BF_REC_SESSION")
    rec_helper_alive "$(jq -r '.pid // ""' <<<"$s")" && alive=true
    secs=$(( ($(rec_ms) - $(jq -r '.startedAt // 0' <<<"$s")) / 1000 ))
  fi
  rec_screen_recording && video=true
  if (( ${JSON:-0} )) || [[ ${1:-} == --json ]]; then
    jq -cn --argjson s "$s" --argjson alive "$alive" --argjson secs "$secs" --argjson video "$video" \
      '{recording: ($s != null), keylogAlive: $alive, videoRecording: $video, seconds: $secs, session: $s}'
  elif [[ $s == null ]]; then
    say "No troubleshooting recording is running."
  else
    say "Recording for ${secs}s into $(jq -r .bundle <<<"$s") (key log $([[ $alive == true ]] && echo running || echo STOPPED))."
  fi
}
