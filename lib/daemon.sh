#!/bin/bash
# Daemon lifecycle. The bar widget calls `daemon ensure` on load and every
# 30 s through Quickshell.execDetached, so the daemon is a detached process
# that survives plugin reloads and shell restarts.

daemon_running() { # exit 0 when another process holds the daemon lock
  [[ -e $OF_RUNTIME/daemon.lock ]] || return 1
  ! flock -n "$OF_RUNTIME/daemon.lock" true 2>/dev/null
}

# The beta-program plugin (fans.omarchy.beta-feedback, 0.1/0.2) kept bundles and
# enrollments here; keep them, out of the way, the first time the new recorder starts.
migrate_legacy_state() {
  local old="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-beta-feedback"
  [[ -d $old && ! -e $OF_STATE/legacy ]] || return 0
  mv -- "$old" "$OF_STATE/legacy" 2>/dev/null && warn "moved the old beta-feedback state to $OF_STATE/legacy"
  return 0
}

cmd_daemon() {
  local sub=${1:-status}
  case "$sub" in
    ensure)
      mkdir -p "$OF_RUNTIME" && chmod 700 "$OF_RUNTIME"
      daemon_running && return 0
      [[ -n ${WAYLAND_DISPLAY:-}${OF_HYPR_DIR:-} ]] || fail "no Wayland session"
      ensure_state
      migrate_legacy_state
      setsid -f python3 "$OF_LIB/feedbackd.py" </dev/null >>"$OF_RUNTIME/daemon.log" 2>&1
      local i; for ((i = 0; i < 50; i++)); do [[ -S $OF_RUNTIME/ctl.sock ]] && daemon_running && return 0; sleep 0.1; done
      warn "daemon did not come up; see $OF_RUNTIME/daemon.log"; return 1 ;;
    status)
      py ofctl.py status ;;
    stop)
      daemon_running || { say "not running"; return 0; }
      py ofctl.py stop >/dev/null || true
      local i; for ((i = 0; i < 50; i++)); do daemon_running || return 0; sleep 0.1; done
      local pid; pid=$(cat "$OF_RUNTIME/daemon.lock" 2>/dev/null)
      [[ $pid =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null
      return 0 ;;
    restart) cmd_daemon stop; cmd_daemon ensure ;;
    *) fail "daemon: ensure|status|stop|restart" ;;
  esac
}

cmd_pause()  { cmd_daemon ensure >/dev/null; py ofctl.py pause; }
cmd_resume() { cmd_daemon ensure >/dev/null; py ofctl.py resume; }
cmd_snap()   { py ofctl.py snap "$@"; }
