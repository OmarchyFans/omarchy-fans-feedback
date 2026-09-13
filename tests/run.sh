#!/bin/bash
# Tests for omarchy-feedback. Everything runs under throwaway XDG dirs with a
# fake Hyprland (tests/fakehypr.py) and stubbed desktop tools on PATH; real
# python3, sqlite3, jq and git are used. Nothing touches the real session.
#   tests/run.sh [group...]     groups: unit lua daemon (default: all)
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
  python3 "$ROOT/tests/fakehypr.py" "$OF_HYPR_DIR" &
  FAKE_PID=$!
  wait_for 5 test -e "$OF_HYPR_DIR/ready" || tfail "fake Hyprland did not start"
}
hypr_emit() { printf '%s\n' "$@" >>"$OF_HYPR_DIR/emit"; }

GROUPS_ALL=(unit lua daemon)
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

echo "== tree: no symlinks, no __pycache__, manifest"
[[ -z $(find "$ROOT" -path "$ROOT/.git" -prune -o -type l -print) ]] || tfail "symlink in tree"
[[ -z $(find "$ROOT" -path "$ROOT/.git" -prune -o -name __pycache__ -print) ]] || tfail "__pycache__ created in the tree"
jq -e '.id=="fans.omarchy.feedback" and .entryPoints.barWidget=="Panel.qml"' "$ROOT/manifest.json" >/dev/null || tfail manifest
pass "tree"
echo "All tests passed."
