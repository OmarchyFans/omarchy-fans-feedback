#!/bin/bash
#
# Optional extras for Feedback. `omarchy plugin add` already installs the
# plugin and the bar chip starts the recorder; this script offers what a plugin
# cannot ship itself, each behind its own confirmation and each idempotent:
#
#   1. symlink bin/omarchy-feedback into ~/.local/bin
#   2. SUPER + ALT + B -> report an issue (appended to ~/.config/hypr/bindings.lua)
#   3. a "Feedback" section in the Omarchy menu (~/.config/omarchy/extensions/omarchy-menu.jsonc)
#   4. the local web viewer as an installed web app (omarchy-webapp-install)
#
# Nothing is overwritten: existing entries are detected and skipped, and a
# timestamped backup is taken before a config file is appended to.
set -euo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN="$REPO/bin/omarchy-feedback"
MARK="fans.omarchy.feedback"
YES=0; [[ ${1:-} == --yes ]] && YES=1
ask() { (( YES )) && return 0; read -rp "$1 [y/N] " a; [[ $a == [yY]* ]]; }

chmod +x "$BIN" 2>/dev/null || true

if ask "Symlink omarchy-feedback into ~/.local/bin?"; then
  mkdir -p "$HOME/.local/bin"; ln -sfn "$BIN" "$HOME/.local/bin/omarchy-feedback"
  echo "  linked ~/.local/bin/omarchy-feedback"
fi

B="$HOME/.config/hypr/bindings.lua"
if [[ -f $B ]] && grep -q "$MARK" "$B"; then
  echo "  keybinding already present in $B"
elif [[ -f $B ]] && grep -qE '^[^-]*"SUPER \+ ALT \+ B"' "$B"; then
  echo "  SUPER + ALT + B is already bound in $B; skipped (bind 'omarchy-feedback capture --source key' yourself)"
elif ask "Add SUPER + ALT + B -> Report an issue to $B?"; then
  [[ -f $B ]] && cp -a "$B" "$B.bak.$(date +%s)"
  cat >>"$B" <<LUA

-- Feedback ($MARK): capture a screenshot and the events that led up to now.
-- SUPER + ALT + B was unbound (SUPER + SHIFT + B is Omarchy's Browser).
o.bind("SUPER + ALT + B", "Report an issue", "$HOME/.config/omarchy/plugins/$MARK/bin/omarchy-feedback capture --source key")
LUA
  echo "  appended; run 'hyprctl reload && hyprctl configerrors' to verify"
fi

M="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
if [[ -f $M ]] && grep -q '"feedback.report"' "$M"; then
  echo "  menu entries already present in $M"
elif ask "Add a Feedback section to the Omarchy menu ($M)?"; then
  mkdir -p "$(dirname "$M")"
  if [[ -f $M ]]; then
    cp -a "$M" "$M.bak.$(date +%s)"
    python3 - "$M" "$REPO/extensions/omarchy-menu.snippet.jsonc" <<'PY'
import sys
path, snippet = sys.argv[1], open(sys.argv[2]).read().rstrip().rstrip(",") + "\n"
s = open(path).read()
i = s.rstrip().rfind("}")
if i < 0: sys.exit("no closing brace in " + path)
head = s[:i].rstrip()
sep = "" if head.endswith(",") or head.endswith("{") else ","
open(path, "w").write(head + sep + "\n" + snippet + s[i:])
PY
  else
    { echo "{"; sed '$ s/,$//' "$REPO/extensions/omarchy-menu.snippet.jsonc"; echo "}"; } >"$M"
  fi
  echo "  appended; the menu hot-reloads"
fi

if command -v omarchy-webapp-install >/dev/null && ask "Install the Feedback viewer as a web app (launcher entry)?"; then
  omarchy-webapp-install "Feedback" "http://127.79.33.1:7741/" "$REPO/web/icon.png" "$BIN open" && echo "  installed the Feedback web app"
fi
echo "Done. Enable the bar chip with: omarchy plugin enable $MARK"
