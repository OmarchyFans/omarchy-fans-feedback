#!/bin/bash
# Scripted answers for the gum wrappers: one answer per line in $OF_ANSWERS;
# every prompt is appended to $OF_ASKED so tests can assert the order.
_of_answer() { local a; IFS= read -r a <"$OF_ANSWERS" || a=""; sed -i '1d' "$OF_ANSWERS"; printf '%s\n' "$1" >>"$OF_ASKED"; printf '%s' "$a"; }
ui_choose()  { local a; a=$(_of_answer "choose: $1"); [[ $a == "<cancel>" ]] && return 1; if [[ -n $a ]]; then printf '%s' "$a"; else printf '%s' "$2"; fi; }
ui_filter()  { ui_choose "$@"; }
ui_input()   { local a; a=$(_of_answer "input: $1"); [[ $a == "<cancel>" ]] && return 1; printf '%s' "$a"; }
ui_write()   { _of_answer "write: $1"; }
ui_confirm() { [[ $(_of_answer "confirm: $1") == y ]]; }
ui_style()   { printf '%s\n' "$*"; }
