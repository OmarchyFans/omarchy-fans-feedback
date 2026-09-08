#!/bin/bash
# Reverses install.sh: removes the ~/.local/bin symlink and the menu entries.
# Leaves ~/.local/state/omarchy-beta-feedback (your reports) unless --purge.
set -euo pipefail
L="$HOME/.local/bin/omarchy-beta-feedback"
[[ -L $L ]] && rm -f "$L" && echo "  removed $L"
M="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
if [[ -f $M ]] && grep -q '"beta-feedback"' "$M"; then
  cp -a "$M" "$M.bak.$(date +%s)"
  python3 - "$M" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p).read()
s = re.sub(r'\n  // Beta Feedback \(fans\.omarchy\.beta-feedback\)\n  "beta-feedback": \{.*?\n  \},\n', '\n', s, flags=re.S)
open(p, "w").write(s)
PY
  echo "  removed menu entries from $M"
fi
if [[ ${1:-} == --purge ]]; then
  rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-beta-feedback" "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-beta-feedback"
  echo "  purged state and config"
fi
echo "Done. Remove the plugin itself with: omarchy plugin remove fans.omarchy.beta-feedback"
