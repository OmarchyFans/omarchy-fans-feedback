#!/bin/bash
# Scripted answers for the gum wrappers: one answer per line in $BF_ANSWERS;
# every prompt is appended to $BF_ASKED so tests can assert the order.
_bf_answer() { local a; IFS= read -r a <"$BF_ANSWERS" || a=""; sed -i '1d' "$BF_ANSWERS"; printf '%s\n' "$1" >>"$BF_ASKED"; printf '%s' "$a"; }
ui_choose()  { local a; a=$(_bf_answer "choose: $1"); [[ $a == "<cancel>" ]] && return 1; if [[ -n $a ]]; then printf '%s' "$a"; else printf '%s' "$2"; fi; }
ui_input()   { _bf_answer "input: $1"; }
ui_write()   { _bf_answer "write: $1"; }
ui_confirm() { [[ $(_bf_answer "confirm: $1") == y ]]; }
ui_style()   { printf '%s\n' "$*"; }
ui_pager()   { :; }
