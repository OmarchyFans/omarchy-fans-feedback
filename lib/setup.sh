#!/bin/bash
# First-run setup. `omarchy plugin add` only clones and enables a plugin; it has
# no install hook, so the extras in install.sh (command link, SUPER + ALT + B,
# Omarchy menu section, web app) were left for the user to find. The bar chip
# calls `omarchy-feedback setup --auto` on load: the first time it runs, it
# installs them unattended (install.sh --yes is idempotent and never replaces an
# existing binding or menu entry), then leaves a marker so it never runs again.
# Removing an extra by hand afterwards is respected.
#
#   omarchy-feedback setup           run install.sh now (asks per step in a terminal)
#   omarchy-feedback setup --auto    once per state dir, unattended; skipped when
#                                    "auto_setup": false is in config.json

OF_SETUP_MARK="$OF_STATE/setup-done"

cmd_setup() {
  local auto=0
  [[ ${1:-} == --auto ]] && auto=1
  if (( ! auto )); then
    run "$OF_ROOT/install.sh"
    return
  fi
  [[ -e $OF_SETUP_MARK ]] && return 0
  if [[ -f $OF_CONFIG ]] && jq -e '.auto_setup == false' "$OF_CONFIG" >/dev/null 2>&1; then
    return 0
  fi
  ensure_state
  local log="$OF_STATE/setup.log"
  if (( OF_DRY_RUN )); then
    run "$OF_ROOT/install.sh" --yes
    return 0
  fi
  if "$OF_ROOT/install.sh" --yes </dev/null >"$log" 2>&1; then
    printf '%s\n' "$OF_VERSION" >"$OF_SETUP_MARK"
    have hyprctl && hyprctl reload >/dev/null 2>&1   # pick up the new keybinding now
    notify "Feedback is set up" "SUPER + ALT + B reports an issue. Also added: the omarchy-feedback command, a Feedback section in the Omarchy menu and the viewer web app. Details: $log"
  else
    # No marker: the next chip load tries again.
    notify "Feedback setup did not finish" "See $log, or run: omarchy-feedback setup"
    return 1
  fi
}
