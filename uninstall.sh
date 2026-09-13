#!/bin/bash
# Reverses install.sh: stops the recorder, removes the ~/.local/bin symlink, the
# keybinding and the menu entries. Keeps ~/.local/state/omarchy-feedback (your
# issues) unless --purge.
set -euo pipefail
MARK="fans.omarchy.feedback"
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
"$REPO/bin/omarchy-feedback" disarm >/dev/null 2>&1 || true
"$REPO/bin/omarchy-feedback" daemon stop >/dev/null 2>&1 || true
L="$HOME/.local/bin/omarchy-feedback"
[[ -L $L ]] && rm -f "$L" && echo "  removed $L"
B="$HOME/.config/hypr/bindings.lua"
if [[ -f $B ]] && grep -q "$MARK" "$B"; then
  cp -a "$B" "$B.bak.$(date +%s)"
  python3 - "$B" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
s = re.sub(r'\n-- Feedback \(fans\.omarchy\.feedback\).*?\no\.bind\("SUPER \+ ALT \+ B".*?\n', '\n', s, flags=re.S)
open(p, "w").write(s)
PY
  echo "  removed the keybinding from $B"
fi
M="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
if [[ -f $M ]] && grep -q '"feedback.report"' "$M"; then
  cp -a "$M" "$M.bak.$(date +%s)"
  python3 - "$M" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
s = re.sub(r'\n  // Feedback \(fans\.omarchy\.feedback\)\n(  "feedback[^\n]*\n)+', '\n', s)
s = re.sub(r',(\s*)\}\s*$', r'\1}\n', s)   # install.sh added a comma after the previous last entry
open(p, "w").write(s)
PY
  echo "  removed menu entries from $M"
fi
if [[ ${1:-} == --purge ]]; then
  rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-feedback" "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-feedback"
  echo "  purged issues, settings and config"
fi
echo "Done. Remove the plugin itself with: omarchy plugin remove $MARK"
