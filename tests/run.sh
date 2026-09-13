#!/bin/bash
# Tests for omarchy-feedback. Everything runs under throwaway XDG dirs with a
# fake Hyprland (tests/fakehypr.py) and stubbed desktop tools on PATH; real
# python3, sqlite3, jq and git are used. Nothing touches the real session.
#   tests/run.sh [group...]     groups: unit lua daemon capture install (default: all)
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
FAKE_PID=""
cleanup() {
  [[ -n $FAKE_PID ]] && { touch "$T/hypr/quit"; wait "$FAKE_PID" 2>/dev/null || true; }
  if [[ -S $T/run/ctl.sock ]]; then OF_RUNTIME="$T/run" python3 "$ROOT/lib/ofctl.py" stop >/dev/null 2>&1 || true; sleep 0.3; fi
  rm -rf "$T"
}
trap cleanup EXIT

export HOME="$T/home" XDG_CONFIG_HOME="$T/config" XDG_STATE_HOME="$T/state" XDG_DATA_HOME="$T/data"
export XDG_RUNTIME_DIR="$T/xdg-run" OF_RUNTIME="$T/run" OF_STATE="$T/state/omarchy-feedback" OF_HYPR_DIR="$T/hypr"
export OF_UI_STUBS="$ROOT/tests/ui-stubs.sh" OF_ANSWERS="$T/answers" OF_ASKED="$T/asked" OF_TEST_LOG="$T/log" OF_TEST_DIR="$T"
export OF_TICK=0.2 OF_HYPR_WAIT=5 PYTHONDONTWRITEBYTECODE=1
export PATH="$ROOT/tests/stubs:$PATH" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
: >"$OF_TEST_LOG"; : >"$OF_ASKED"; : >"$OF_ANSWERS"
B="$ROOT/bin/omarchy-feedback"
pass() { echo "  ok   $*"; }
tfail() { echo "  FAIL $*"; [[ -s $OF_TEST_LOG ]] && { echo "--- log"; tail -n 30 "$OF_TEST_LOG"; }; [[ -s $OF_RUNTIME/daemon.log ]] && { echo "--- daemon.log"; tail -n 20 "$OF_RUNTIME/daemon.log"; }; exit 1; }
j() { jq -r "$1" <<<"$2"; }
wait_for() { # wait_for <seconds> <command...>
  local n=$(( $1 * 10 )); shift
  while (( n-- > 0 )); do "$@" && return 0; sleep 0.1; done
  return 1
}
seg_has() { cat "$OF_RUNTIME"/seg/*.jsonl 2>/dev/null | grep -q -- "$1"; }
daemon_gone() { ! pgrep -f "^python3 $ROOT/lib/feedbackd.py" >/dev/null; }

start_fakehypr() {
  [[ -n $FAKE_PID ]] && return 0
  rm -f "$OF_HYPR_DIR/quit" "$OF_HYPR_DIR/ready"
  python3 "$ROOT/tests/fakehypr.py" "$OF_HYPR_DIR" &
  FAKE_PID=$!
  wait_for 5 test -e "$OF_HYPR_DIR/ready" || tfail "fake Hyprland did not start"
}
hypr_emit() { printf '%s\n' "$@" >>"$OF_HYPR_DIR/emit"; }

GROUPS_ALL=(unit lua daemon capture install)
want() { local g; for g in "${SELECTED[@]}"; do [[ $g == "$1" ]] && return 0; done; return 1; }
SELECTED=("$@"); (( ${#SELECTED[@]} )) || SELECTED=("${GROUPS_ALL[@]}")

# ---------------------------------------------------------------------------
if want unit; then
  echo "== unit: rolling log, key decoder, Hyprland parsing"
  python3 "$ROOT/tests/test_events.py" >"$T/unit.out" 2>&1 || { cat "$T/unit.out"; tfail "python unit tests"; }
  pass "python unit tests"
fi

if want lua; then
  echo "== lua: the chunks sent to hyprctl eval, under a mock hl"
  if command -v lua >/dev/null; then
    L="$T/lua"; mkdir -p "$L"
    PY="import sys; sys.path.insert(0, '$ROOT/lib'); import of_keys as k"
    python3 -c "$PY; print(k.lua_arm('$L/raw'), end='')" >"$L/arm.lua"
    python3 -c "$PY; print(k.lua_arm('$L/raw', all_keys=True), end='')" >"$L/armall.lua"
    python3 -c "$PY; print(k.LUA_DISARM, end='')" >"$L/disarm.lua"
    lua "$ROOT/tests/lua_listener_test.lua" "$L/arm.lua" "$L/armall.lua" "$L/disarm.lua" >/dev/null || tfail "lua chunk test"
    expected=$'K ? 1 0\nK ? 0 0\nK 50 1 0\nK 113 1 0\nK 113 0 0\nK 50 0 0\nK 37 1 0\nK 54 1 0\nK 54 0 0\nK 37 0 0\nK 108 1 0\nK ? 1 0\nK ? 0 0\nK 108 0 0\nK 202 1 0\nS resize\nK 38 1 0'
    [[ $(cat "$L/raw") == "$expected" ]] || tfail "lua redaction output: $(cat "$L/raw")"
    pass "letters hidden, shortcuts shown, pause, idempotent re-arm, disarm"
  else
    echo "  skip (lua not installed)"
  fi
fi

if want daemon; then
  echo "== daemon: ensure, events, keys, lock pause, snapshot, pause/resume, stop"
  start_fakehypr
  "$B" daemon ensure || tfail "daemon ensure"
  "$B" daemon ensure || tfail "second ensure must be a no-op"
  [[ $(pgrep -fc "^python3 $ROOT/lib/feedbackd.py") == 1 ]] || tfail "exactly one daemon expected, got $(pgrep -fc "^python3 $ROOT/lib/feedbackd.py")"
  st=$("$B" daemon status) || tfail "status"
  [[ $(j .running "$st") == true && $(j .keyListener "$st") == true && $(j .hyprland "$st") == true ]] || tfail "status: $st"
  grep -q "hyprctl eval local paused, all = false, false" "$OF_TEST_LOG" || tfail "key listener armed"
  [[ $(stat -c %a "$OF_RUNTIME") == 700 && $(stat -c %a "$OF_RUNTIME/keys.raw") == 600 && $(stat -c %a "$OF_RUNTIME/ctl.sock") == 600 ]] \
    || tfail "runtime permissions"
  [[ -s $OF_RUNTIME/status.json ]] || tfail "status.json heartbeat"

  hypr_emit "activewindow>>org.omarchy.agent,Rix · chat" "openlayer>>omarchy-menu" "mouse>>ignored"
  wait_for 5 seg_has '"class":"org.omarchy.agent"' || tfail "window event not logged"
  wait_for 5 seg_has '"type":"cursor"' || tfail "cursor sampled after focus/layer change"
  seg_has 'ignored' && tfail "unknown socket2 events must not be logged"
  printf 'K 133 1 0\nK 36 1 0\nK 36 0 0\nK 133 0 0\nK ? 1 0\nK ? 0 0\n' >>"$OF_RUNTIME/keys.raw"
  wait_for 5 seg_has '"combo":"Super+Enter"' || tfail "key combo not logged"
  seg_has '"redacted":true' || tfail "redacted key press not logged as redacted"
  [[ $(stat -c %a "$OF_RUNTIME"/seg/*.jsonl | sort -u) == 600 ]] || tfail "segment permissions"
  pass "window, layer, cursor and key events reach the rolling log"

  : >"$OF_TEST_LOG"
  touch "$OF_HYPR_DIR/locked"
  wait_for 5 seg_has '"type":"lock","locked":true' || tfail "lock not detected"
  grep -q "hyprctl eval local paused, all = true, false" "$OF_TEST_LOG" || tfail "key listener paused on lock"
  rm -f "$OF_HYPR_DIR/locked"
  wait_for 5 seg_has '"type":"lock","locked":false' || tfail "unlock not detected"
  pass "key listener pauses while locked"

  out=$("$B" snap "$T/issue/events.jsonl" 10) || tfail "snap"
  [[ $(j .ok "$out") == true ]] && (( $(j .events "$out") >= 4 )) || tfail "snap result: $out"
  grep -q '"combo":"Super+Enter"' "$T/issue/events.jsonl" && grep -q '"type":"mark"' "$T/issue/events.jsonl" || tfail "snapshot content"
  desc=$(python3 "$ROOT/lib/ofctl.py" describe "$T/issue/events.jsonl")
  grep -q "focus org.omarchy.agent — Rix · chat" <<<"$desc" && grep -q "key Super+Enter" <<<"$desc" || tfail "describe: $desc"
  pass "snapshot copies the recent window and renders a timeline"

  "$B" pause >/dev/null || tfail pause
  [[ $(jq -r .paused "$OF_STATE/settings.json") == true ]] || tfail "pause persisted"
  hypr_emit "activewindow>>secret.app,should not be logged"
  sleep 0.6
  seg_has "secret.app" && tfail "events logged while paused"
  "$B" resume >/dev/null || tfail resume
  hypr_emit "activewindow>>kitty,after resume"
  wait_for 5 seg_has "after resume" || tfail "events after resume"
  pass "pause stops the log and persists; resume restarts it"

  : >"$OF_TEST_LOG"
  "$B" daemon stop || tfail "stop"
  wait_for 5 daemon_gone || tfail "daemon still running"
  grep -q "hyprctl eval local r = _G.ofrec" "$OF_TEST_LOG" || tfail "Lua listener disarmed on stop"
  [[ ! -e $OF_RUNTIME/keys.raw && ! -e $OF_RUNTIME/ctl.sock && ! -e $OF_RUNTIME/status.json ]] || tfail "runtime files left: $(ls "$OF_RUNTIME")"
  st=$("$B" daemon status) && tfail "status must fail when stopped"
  [[ $(j .running "$st") == false ]] || tfail "stopped status: $st"
  out=$("$B" snap "$T/issue/fallback.jsonl" 10) || tfail "fallback snap"
  [[ $(j .fallback "$out") == true ]] && grep -q "after resume" "$T/issue/fallback.jsonl" || tfail "fallback snap reads segments: $out"
  pass "stop disarms and cleans up; snap still works from the segments"

  "$B" daemon ensure || tfail "restart after stop"
  touch "$OF_HYPR_DIR/quit"; wait "$FAKE_PID" 2>/dev/null || true; FAKE_PID=""
  wait_for 5 daemon_gone || tfail "daemon must exit when Hyprland goes away"
  pass "daemon exits when Hyprland's event socket closes"
fi

if want capture; then
  echo "== capture: attribution, screenshot + crop, event snapshot, replay save, database, form, list/set/delete"
  start_fakehypr
  "$B" daemon ensure || tfail "daemon ensure"
  export OF_PLUGINS_DIR="$T/plugins"
  mkdir -p "$OF_PLUGINS_DIR/test.plugin" "$T/src/other"
  printf '{"schemaVersion":1,"id":"test.plugin","name":"Test Plugin","version":"1.2.3","author":"modpunk","kinds":["bar-widget"],"entryPoints":{"barWidget":"P.qml"}}\n' \
    >"$OF_PLUGINS_DIR/test.plugin/manifest.json"
  git init -q "$OF_PLUGINS_DIR/test.plugin" && git -C "$OF_PLUGINS_DIR/test.plugin" remote add origin git@github.com:modpunk/test-plugin.git
  mkdir -p "$OF_PLUGINS_DIR/local.plugin"
  printf '{"schemaVersion":1,"id":"local.plugin","name":"Local","version":"0.1.0","author":"me","kinds":["bar-widget"],"entryPoints":{"barWidget":"P.qml"}}\n' \
    >"$OF_PLUGINS_DIR/local.plugin/manifest.json"
  git init -q "$T/src/other" && git -C "$T/src/other" remote add origin https://github.com/me/local-plugin.git
  git init -q "$OF_PLUGINS_DIR/local.plugin" && git -C "$OF_PLUGINS_DIR/local.plugin" remote add origin "$T/src/other"
  printf '{"class":"kitty","title":"~/Work","pid":%d,"at":[10,40],"size":[600,400],"monitor":0,"workspace":{"name":"2"}}\n' $$ >"$OF_HYPR_DIR/activewindow.json"

  s=$(python3 "$ROOT/lib/of_subject.py" plugin test.plugin)
  [[ $(j .repo "$s") == https://github.com/modpunk/test-plugin && $(j .version "$s") == 1.2.3 && $(j .author "$s") == modpunk ]] || tfail "plugin subject: $s"
  s=$(python3 "$ROOT/lib/of_subject.py" plugin local.plugin)
  [[ $(j .repo "$s") == https://github.com/me/local-plugin && $(j .localCheckout "$s") == "$T/src/other" ]] || tfail "local-origin plugin subject: $s"
  pass "plugin attribution follows git origin (and one local hop)"

  hypr_emit "activewindow>>kitty,~/Work" "openwindow>>0xabc,2,kitty,~/Work"
  printf 'K 133 1 0\nK 36 1 0\nK 36 0 0\nK 133 0 0\n' >>"$OF_RUNTIME/keys.raw"
  wait_for 5 seg_has '"combo":"Super+Enter"' || tfail "events before capture"

  : >"$OF_TEST_LOG"
  out=$("$B" arm 30 --json) || tfail "arm: $out"
  [[ $(j .armed "$out") == true && $(j .monitor "$out") == eDP-1 && $(j .seconds "$out") == 30 ]] || tfail "arm result: $out"
  wait_for 5 grep -q "gpu-screen-recorder -w eDP-1 -c mp4 -f 30 -r 30 -replay-storage ram" "$OF_TEST_LOG" || tfail "recorder argv"
  grep -q -- "-write-first-frame-ts yes -o $OF_STATE/replays -ipc $OF_RUNTIME/replay.sock" "$OF_TEST_LOG" || tfail "recorder output/ipc args"
  wait_for 5 test -S "$OF_RUNTIME/replay.sock" || tfail "replay ipc socket"
  [[ $("$B" daemon status | jq -r .replay.armed) == true ]] || tfail "status shows armed"
  pass "arm starts the RAM replay buffer on the focused monitor"

  out=$("$B" capture --no-form --json --source key --title "Launcher ignores the second click" \
        --subject plugin:test.plugin --description "Click Launch twice; nothing happens.") || tfail "scripted capture: $out"
  id=$(j .id "$out"); D="$OF_STATE/issues/$id"
  for f in shot.png window.png events.jsonl replay.mp4 replay.mp4.ts summary.md meta.json env.json; do
    [[ -s $D/$f ]] || tfail "issue file missing: $f ($(ls "$D"))"
  done
  [[ -z $(ls -d "$OF_STATE"/issues/.pending-* 2>/dev/null) ]] || tfail "pending folder left behind"
  grep -q "grim -o eDP-1 " "$OF_TEST_LOG" || tfail "grim on the focused monitor"
  grep -q "crop=900:600:15:60" "$OF_TEST_LOG" || tfail "window crop scaled by the monitor scale: $(grep ffmpeg "$OF_TEST_LOG")"
  g=$(python3 "$ROOT/lib/of_db.py" get "$id")
  [[ $(j .subject_type "$g") == plugin && $(j .subject_id "$g") == test.plugin && $(j .repo_url "$g") == https://github.com/modpunk/test-plugin ]] || tfail "subject in db: $g"
  [[ $(j '[.attachments[].kind] | sort | join(",")' "$g") == "events,replay,screenshot,summary,window" ]] || tfail "attachments: $(j '[.attachments[].kind]' "$g")"
  [[ $(j '.attachments[] | select(.kind=="replay") | .meta.firstFrameMs > 0' "$g") == true ]] || tfail "replay first-frame timestamp"
  (( $(j .event_count "$g") >= 3 )) || tfail "events stored: $(j .event_count "$g")"
  [[ $(j .context.activewindow.class "$g") == kitty && $(j .status "$g") == new && $(j .source "$g") == key ]] || tfail "context: $g"
  grep -q "^# Launcher ignores the second click" "$D/summary.md" && grep -q "Leading up to the report" "$D/summary.md" \
    && grep -q "key Super+Enter" "$D/summary.md" && grep -q "| Project | https://github.com/modpunk/test-plugin |" "$D/summary.md" || tfail "summary.md: $(cat "$D/summary.md")"
  grep -q "notify --app-name Feedback -g 󰃤 Feedback #$id saved" "$OF_TEST_LOG" || tfail "saved notification"
  [[ -z $(ls "$OF_STATE/replays" 2>/dev/null) ]] || tfail "saved replay must move into the issue folder"
  pass "scripted capture: screenshot, crop, events, replay, db row, summary"

  : >"$OF_TEST_LOG"
  printf '%s\n' "App: bash 5.3.9-1 — ~/Work" feature "Add a dark mode" "It is too bright at night." >"$OF_ANSWERS"
  out=$(OF_POPUP=1 "$B" capture --json --source chip) || tfail "form capture: $out"
  id2=$(j .id "$out"); g=$(python3 "$ROOT/lib/of_db.py" get "$id2")
  [[ $(j .kind "$g") == feature && $(j .title "$g") == "Add a dark mode" && $(j .subject_type "$g") == app \
     && $(j .subject_name "$g") == bash && $(j .repo_url "$g") == https://www.gnu.org/software/bash/bash.html ]] || tfail "form issue: $g"
  [[ -s $OF_STATE/issues/$id2/annotated.png ]] && grep -q "tensaku -f .*shot.png -o .*annotated.png" "$OF_TEST_LOG" || tfail "tensaku markup at capture"
  grep -q "choose: What is this about?" "$OF_ASKED" || tfail "subject asked"
  pass "interactive capture: Tensaku markup, subject picked from candidates, form fields"

  n_before=$(python3 "$ROOT/lib/of_db.py" list --status all | jq length)
  printf '%s\n' "<cancel>" y >"$OF_ANSWERS"
  OF_POPUP=1 "$B" capture --source key --no-annotate >/dev/null || tfail "cancelled capture exit"
  [[ $(python3 "$ROOT/lib/of_db.py" list --status all | jq length) == "$n_before" ]] || tfail "cancel + discard must not save"
  [[ -z $(ls -d "$OF_STATE"/issues/.pending-* 2>/dev/null) ]] || tfail "discarded pending folder left"
  printf '%s\n' "<cancel>" n >"$OF_ANSWERS"
  OF_POPUP=1 "$B" capture --source key --no-annotate >/dev/null || tfail "cancel keep exit"
  [[ $(python3 "$ROOT/lib/of_db.py" list --status all | jq -r '.[0].title') == "Untitled feedback" ]] || tfail "cancel + keep saves untitled"
  "$B" capture-form /tmp >/dev/null 2>&1 && tfail "capture-form must refuse arbitrary folders"
  pass "cancel discards or keeps as untitled; capture-form only takes pending folders"

  l=$("$B" list --json); [[ $(jq length <<<"$l") == 3 ]] || tfail "list open: $l"
  "$B" set "$id" status fixed >/dev/null || tfail "set status"
  "$B" set "$id" notes "Fixed in 1.2.4" >/dev/null || tfail "set notes"
  [[ $("$B" list --json | jq length) == 2 && $("$B" list --status fixed --json | jq -r '.[0].id') == "$id" ]] || tfail "status filter"
  g=$(python3 "$ROOT/lib/of_db.py" get "$id")
  [[ $(j '.status_log | map(.to_status) | join(",")' "$g") == "new,fixed" && $(j .notes "$g") == "Fixed in 1.2.4" ]] || tfail "status log/notes: $g"
  grep -q "Fixed in 1.2.4" "$OF_STATE/issues/$id/summary.md" || tfail "summary refreshed after set"
  "$B" set "$id" status nonsense >/dev/null 2>&1 && tfail "invalid status accepted"
  "$B" list | grep -q "Add a dark mode" || tfail "human list"
  last=$("$B" list --json | jq -r '.[0].id')
  "$B" delete "$last" >/dev/null && [[ ! -d $OF_STATE/issues/$last ]] || tfail "delete"
  pass "list, status workflow with log, notes, delete"

  "$B" disarm >/dev/null || tfail disarm
  [[ $("$B" daemon status | jq -r .replay.armed) == false ]] || tfail "disarmed status"
  out=$("$B" capture --no-form --json --title "No replay this time" --subject omarchy) || tfail "capture without replay"
  g=$(python3 "$ROOT/lib/of_db.py" get "$(j .id "$out")")
  [[ $(j .subject_type "$g") == omarchy && $(j .repo_url "$g") == https://github.com/basecamp/omarchy ]] || tfail "omarchy subject: $g"
  j '[.attachments[].kind] | index("replay")' "$g" | grep -q null || tfail "no replay expected when disarmed"
  "$B" arm >/dev/null || tfail "re-arm"
  touch "$OF_HYPR_DIR/locked"
  wait_for 5 bash -c "\"$B\" daemon status | jq -e '.replay.armed == false and (.replay.lastEnded | test(\"locked\"))' >/dev/null" || tfail "auto-disarm on lock"
  "$B" arm >/dev/null 2>&1 && tfail "arming while locked must be refused"
  rm -f "$OF_HYPR_DIR/locked"
  wait_for 5 bash -c "\"$B\" daemon status | jq -e '.locked == false' >/dev/null" || tfail "unlock detected"
  "$B" arm >/dev/null || tfail "arm after unlock"
  hypr_emit "focusedmon>>HDMI-A-1,3"
  wait_for 5 bash -c "\"$B\" daemon status | jq -e '.replay.armed == false and (.replay.lastEnded | test(\"HDMI-A-1\"))' >/dev/null" || tfail "auto-disarm on monitor change"
  pass "disarm, no replay when off, auto-disarm on lock and monitor change"
  "$B" daemon stop
fi

if want install; then
  echo "== install.sh / uninstall.sh against a throwaway home"
  mkdir -p "$HOME/.config/hypr" "$HOME/.config/omarchy/extensions"
  printf -- '-- personal bindings\no.bind("SUPER + A", "Claude profile", "claude-profile-menu")\n' >"$HOME/.config/hypr/bindings.lua"
  printf '{\n  "agents": {"icon":"x","label":"Agents"}\n}\n' >"$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
  : >"$OF_TEST_LOG"
  "$ROOT/install.sh" --yes >/dev/null || tfail "install.sh"
  "$ROOT/install.sh" --yes >/dev/null || tfail "install.sh second run"
  [[ -L $HOME/.local/bin/omarchy-feedback ]] || tfail "CLI symlink"
  [[ $(grep -c 'o.bind("SUPER + ALT + B", "Report an issue"' "$HOME/.config/hypr/bindings.lua") == 1 ]] || tfail "binding appended once"
  M="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
  [[ $(grep -c '"feedback.report"' "$M") == 1 ]] || tfail "menu appended once"
  python3 -c "import json,re,sys; s=open(sys.argv[1]).read(); json.loads(re.sub(r'^\s*//.*$', '', s, flags=re.M))" "$M" || tfail "menu file is not valid JSONC: $(cat "$M")"
  grep -q "omarchy-webapp-install Feedback http://127.79.33.1:7741/" "$OF_TEST_LOG" || tfail "web app install offered"
  printf -- '-- other\no.bind("SUPER + ALT + B", "Mine", "foo")\n' >"$T/b2.lua"
  HOME2="$T/home2"; mkdir -p "$HOME2/.config/hypr"; cp "$T/b2.lua" "$HOME2/.config/hypr/bindings.lua"
  out=$(HOME="$HOME2" "$ROOT/install.sh" --yes) || tfail "install.sh with an existing binding"
  grep -q "already bound" <<<"$out" && [[ $(cat "$HOME2/.config/hypr/bindings.lua") == "$(cat "$T/b2.lua")" ]] || tfail "must not clobber an existing SUPER + ALT + B: $out"
  "$ROOT/uninstall.sh" >/dev/null || tfail "uninstall.sh"
  [[ ! -e $HOME/.local/bin/omarchy-feedback ]] && ! grep -q "fans.omarchy.feedback" "$HOME/.config/hypr/bindings.lua" \
    && ! grep -q '"feedback' "$M" && grep -q '"agents"' "$M" && grep -q "Claude profile" "$HOME/.config/hypr/bindings.lua" || tfail "uninstall left entries or removed others"
  python3 -c "import json,re,sys; s=open(sys.argv[1]).read(); json.loads(re.sub(r'^\s*//.*$', '', s, flags=re.M))" "$M" || tfail "menu invalid after uninstall: $(cat "$M")"
  pass "idempotent install, no clobbering, clean uninstall"
fi

echo "== tree: no symlinks, no __pycache__, manifest"
[[ -z $(find "$ROOT" -path "$ROOT/.git" -prune -o -type l -print) ]] || tfail "symlink in tree"
[[ -z $(find "$ROOT" -path "$ROOT/.git" -prune -o -name __pycache__ -print) ]] || tfail "__pycache__ created in the tree"
jq -e '.id=="fans.omarchy.feedback" and .entryPoints.barWidget=="Panel.qml"' "$ROOT/manifest.json" >/dev/null || tfail manifest
pass "tree"
echo "All tests passed."
