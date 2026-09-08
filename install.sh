#!/bin/bash
#
# Optional helper for Beta Feedback. `omarchy plugin add` already installs the
# plugin; this script offers the extras a plugin cannot ship, each behind its
# own confirmation and each idempotent:
#
#   1. symlink bin/omarchy-beta-feedback into ~/.local/bin
#   2. append a "Beta feedback" submenu to ~/.config/omarchy/extensions/omarchy-menu.jsonc
#
# Polling for fixes runs inside the bar widget (hourly QML timer); no systemd
# unit is installed. Nothing is overwritten: existing entries are detected and
# skipped, and a timestamped backup is taken before the menu file is appended to.
set -euo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN="$REPO/bin/omarchy-beta-feedback"
YES=0; [[ ${1:-} == --yes ]] && YES=1
ask() { (( YES )) && return 0; read -rp "$1 [y/N] " a; [[ $a == [yY]* ]]; }

chmod +x "$BIN" 2>/dev/null || true

if ask "Symlink omarchy-beta-feedback into ~/.local/bin?"; then
  mkdir -p "$HOME/.local/bin"; ln -sfn "$BIN" "$HOME/.local/bin/omarchy-beta-feedback"
  echo "  linked ~/.local/bin/omarchy-beta-feedback"
fi

M="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
if [[ -f $M ]] && grep -q '"beta-feedback"' "$M"; then
  echo "  menu entry already present in $M"
elif ask "Add a Beta feedback submenu to the Omarchy menu ($M)?"; then
  mkdir -p "$(dirname "$M")"
  if [[ -f $M ]]; then
    cp -a "$M" "$M.bak.$(date +%s)"
    python3 - "$M" "$REPO/extensions/omarchy-menu.snippet.jsonc" <<'PY'
import sys
path, snippet = sys.argv[1], open(sys.argv[2]).read().rstrip() + "\n"
s = open(path).read()
i = s.rstrip().rfind("}")
if i < 0: sys.exit("no closing brace in " + path)
open(path, "w").write(s[:i] + snippet + s[i:])
PY
  else
    { echo "{"; cat "$REPO/extensions/omarchy-menu.snippet.jsonc"; echo "}"; } >"$M"
  fi
  echo "  appended; the menu hot-reloads"
fi
echo "Done. Enable the bar chip with: omarchy plugin enable fans.omarchy.beta-feedback"
