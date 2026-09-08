#!/bin/bash
# End-to-end tests under throwaway XDG dirs with every external tool stubbed
# (tests/stubs on PATH, gum wrappers replaced by scripted answers). Real git,
# jq and sqlite3 are used. Nothing here touches the network or the real shell.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home" XDG_CONFIG_HOME="$T/config" XDG_STATE_HOME="$T/state" XDG_DATA_HOME="$T/data"
export BF_UI_STUBS="$ROOT/tests/ui-stubs.sh" BF_ANSWERS="$T/answers" BF_ASKED="$T/asked" BF_TEST_LOG="$T/log" BF_TEST_DIR="$T"
export PATH="$ROOT/tests/stubs:$PATH" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"; : >"$BF_TEST_LOG"; : >"$BF_ASKED"; : >"$BF_ANSWERS"
B="$ROOT/bin/omarchy-beta-feedback"
pass() { echo "  ok   $*"; }; tfail() { echo "  FAIL $*"; [[ -s $BF_TEST_LOG ]] && { echo "--- log"; cat "$BF_TEST_LOG"; }; exit 1; }
j() { jq -r "$1" <<<"$2"; }

# ---- a fake "upstream" repo (bare) with main + staging, and an installed clone of it
UP="$T/upstream.git"; SRC="$T/src"; PL="$XDG_CONFIG_HOME/omarchy/plugins"; ID=test.plugin
git init -q -b main "$SRC"
cat >"$SRC/manifest.json" <<M
{"schemaVersion":1,"id":"$ID","name":"Test","version":"1.0.0","kinds":["bar-widget"],"entryPoints":{"barWidget":"Panel.qml"}}
M
echo 'Item {}' >"$SRC/Panel.qml"; mkdir -p "$SRC/lib" "$SRC/tests"; echo 'echo thing' >"$SRC/lib/thing.sh"
printf '#!/bin/bash\ngrep -q "fixed by agent" lib/thing.sh\n' >"$SRC/tests/run.sh"; chmod +x "$SRC/tests/run.sh"
git -C "$SRC" add -A && git -C "$SRC" commit -qm "v1"
git init -q --bare "$UP"; git -C "$UP" symbolic-ref HEAD refs/heads/main
git -C "$SRC" remote add origin "$UP"; git -C "$SRC" push -q origin main
mkdir -p "$PL"; git clone -q "$UP" "$PL/$ID"

echo "== status of an unknown plugin"
s=$("$B" status $ID); [[ $(j .status "$s") == unknown && $(j .consented "$s") == false ]] || tfail "unknown status: $s"
[[ $(j .hasRepo "$s") == false ]] || tfail "no github origin yet should mean hasRepo=false"
[[ -d $XDG_STATE_HOME/omarchy-beta-feedback/shots ]] || tfail "status must create shots dir"
pass "status unknown, shots dir created"

echo "== author init vendors the SDK, config, staging"
printf 'modpunk/test-plugin\n' >"$BF_ANSWERS"   # origin is a local bare repo, so init asks for the GitHub slug
"$B" author init "$SRC" >/dev/null || tfail "author init"
grep -q "input: GitHub repo" "$BF_ASKED" || tfail "slug prompt"
[[ -f $SRC/BetaFeedback.qml && -f $SRC/.beta-feedback.json ]] || tfail "vendored files"
[[ $(jq -r .repo "$SRC/.beta-feedback.json") == "modpunk/test-plugin" ]] || tfail "repo slug: $(cat "$SRC/.beta-feedback.json")"
git -C "$SRC" show-ref --verify --quiet refs/heads/staging || tfail "staging branch"
grep -q "gh label create beta-feedback" "$BF_TEST_LOG" || tfail "labels"
git -C "$SRC" add -A && git -C "$SRC" commit -qm "enroll in beta program" && git -C "$SRC" push -q origin main staging
git -C "$PL/$ID" pull -q --ff-only origin main
pass "author init"

echo "== enroll + days-used clock + expiry"
export BF_NOW=2026-09-08
s=$("$B" status $ID); [[ $(j .hasRepo "$s") == true && $(j .repo "$s") == modpunk/test-plugin ]] || tfail "hasRepo after config: $s"
"$B" enroll $ID >/dev/null || tfail enroll
s=$("$B" status $ID); [[ $(j .status "$s") == enrolled && $(j .daysUsed "$s") == 1 && $(j .daysLeft "$s") == 4 ]] || tfail "day1: $s"
s=$("$B" status $ID); [[ $(j .daysUsed "$s") == 1 ]] || tfail "same day must not double count"
for d in 09 10 11 12; do BF_NOW=2026-09-$d "$B" status $ID >/dev/null; done
s=$(BF_NOW=2026-09-12 "$B" status $ID); [[ $(j .daysUsed "$s") == 5 && $(j .status "$s") == enrolled ]] || tfail "day5: $s"
s=$(BF_NOW=2026-09-20 "$B" status $ID); [[ $(j .status "$s") == expired ]] || tfail "expiry: $s"
grep -q "Beta program ended" "$BF_TEST_LOG" || tfail "expiry notification"
"$B" enroll $ID >/dev/null; s=$("$B" status $ID); [[ $(j .status "$s") == enrolled ]] || tfail "re-enroll"
"$B" unenroll other.plugin --declined >/dev/null; [[ $(j .status "$("$B" status other.plugin)") == declined ]] || tfail "declined"
pass "enroll / clock / expiry / re-enroll / declined"

echo "== report via gh: bundle, annotation, body, clipboard, record"
printf 'x' >"$XDG_STATE_HOME/omarchy-beta-feedback/shots/s.png"
printf 'bug\nLaunch does nothing\nClicked launch twice, nothing happened.\nSubmit to github.com/modpunk/test-plugin (gh)\n' >"$BF_ANSWERS"
out=$("$B" report --plugin $ID --branch main --shot "$XDG_STATE_HOME/omarchy-beta-feedback/shots/s.png" \
       --context '[{"t":1,"b":1,"at":"Button[Launch]"},{"t":2,"b":2,"at":"TextField#name"}]' --no-popup 2>&1) || { echo "$out"; tfail "report"; }
bd=$(ls -d "$XDG_STATE_HOME"/omarchy-beta-feedback/bundles/*-$ID | head -n1)
[[ -s $bd/annotated.png && -s $bd/panel.png && -s $bd/env.json && -s $bd/trace.json && -s $bd/body.md ]] || tfail "bundle files: $(ls "$bd")"
grep -q "annotated" "$bd/annotated.png" || tfail "tensaku output not used"
grep -q "tensaku -f" "$BF_TEST_LOG" || tfail "tensaku called"
grep -q 'left click on `Button\[Launch\]`' "$bd/body.md" || tfail "trace in body"
grep -q 'right click on `TextField#name`' "$bd/body.md" || tfail "right click"
grep -q "ReferenceError" "$bd/body.md" || tfail "shell log in body"
grep -q "DEBUG" "$bd/body.md" && ! grep -q $'\e' "$bd/body.md" || tfail "ansi stripped"
grep -q "| Hyprland | v0.56.0 |" "$bd/body.md" || tfail "env table"
grep -q "<!-- beta-feedback kind=bug reporter=bf-" "$bd/body.md" || tfail "marker"
grep -q "gh issue create -R modpunk/test-plugin --title Launch does nothing --body-file .* --label beta-feedback" "$BF_TEST_LOG" || tfail "gh issue create"
grep -q "wl-copy --type image/png" "$BF_TEST_LOG" || tfail "screenshot on clipboard"
grep -q "Screenshot copied" "$BF_TEST_LOG" || tfail "paste notification"
r=$(tail -n1 "$XDG_STATE_HOME/omarchy-beta-feedback/reports.jsonl")
[[ $(j .issue "$r") == 42 && $(j .status "$r") == open && $(j .plugin "$r") == $ID ]] || tfail "report record: $r"
s=$("$B" status $ID); [[ $(j '.reports|length' "$s") == 1 ]] || tfail "status lists reports"
pass "gh report"

echo "== report via browser when gh is not authenticated"
: >"$BF_TEST_LOG"
printf 'feature\nAdd dark icons\n\nOpen github.com/modpunk/test-plugin in the browser\n' >"$BF_ANSWERS"
BF_GH_NOAUTH=1 "$B" report --plugin $ID --branch main --context '[]' --no-popup >/dev/null 2>&1 || tfail "browser report"
grep -q "xdg-open https://github.com/modpunk/test-plugin/issues/new?title=Add%20dark%20icons&body=.*labels=beta-feedback" "$BF_TEST_LOG" || tfail "browser url"
r=$(tail -n1 "$XDG_STATE_HOME/omarchy-beta-feedback/reports.jsonl"); [[ $(j .status "$r") == browser && $(j .issue "$r") == null ]] || tfail "browser record"
pass "browser report"

echo "== bundle-only"
printf 'bug\nOffline one\nno network\nSave the bundle only (nothing leaves this machine)\n' >"$BF_ANSWERS"; : >"$BF_TEST_LOG"
"$B" report --plugin $ID --context '[]' --no-popup >/dev/null 2>&1 || tfail "bundle-only"
grep -q "gh issue create\|xdg-open" "$BF_TEST_LOG" && tfail "bundle-only must not submit"
pass "bundle-only"

echo "== poll: browser report gets its number by marker search; fixed-in-beta triggers the update nudge"
bb=$(jq -r 'select(.status=="browser") | .bundle' "$XDG_STATE_HOME/omarchy-beta-feedback/reports.jsonl")
echo "{\"items\":[{\"number\":43,\"html_url\":\"https://github.com/modpunk/test-plugin/issues/43\",\"state\":\"open\",\"labels\":[{\"name\":\"beta-feedback\"}]}]}" >"$T/search.json"
cat >"$T/api.json" <<A
[{"number":42,"title":"Launch does nothing","state":"open","labels":[{"name":"beta-feedback"},{"name":"fixed-in-beta"}],"updated_at":"2026-09-09T00:00:00Z","html_url":"https://github.com/modpunk/test-plugin/issues/42","body":"x"},
 {"number":43,"title":"Add dark icons","state":"open","labels":[{"name":"beta-feedback"}],"updated_at":"2026-09-09T00:00:00Z","html_url":"https://github.com/modpunk/test-plugin/issues/43","body":"y"}]
A
# put a fix on staging upstream so ls-remote differs from the installed sha
git -C "$SRC" switch -q staging && echo fix >>"$SRC/lib/thing.sh" && git -C "$SRC" commit -qam "fix on staging" && git -C "$SRC" push -q origin staging && git -C "$SRC" switch -q main
: >"$BF_TEST_LOG"
BF_GH_SEARCH_FILE="$T/search.json" BF_GH_API_FILE="$T/api.json" "$B" poll || tfail "poll"
r=$(jq -c "select(.bundle==\"$bb\")" "$XDG_STATE_HOME/omarchy-beta-feedback/reports.jsonl"); [[ $(j .issue "$r") == 43 && $(j .status "$r") == open ]] || tfail "marker match: $r"
r=$(jq -c 'select(.issue==42)' "$XDG_STATE_HOME/omarchy-beta-feedback/reports.jsonl"); [[ $(j .status "$r") == fixed-in-beta ]] || tfail "label → status: $r"
s=$("$B" status $ID); [[ $(j .updateAvailable "$s") == true ]] || tfail "updateAvailable: $s"
grep -q "test.plugin: a fix for your report is ready to test .* --exec .*omarchy-beta-feedback update test.plugin --channel beta" "$BF_TEST_LOG" || tfail "nudge notification"
: >"$BF_TEST_LOG"; BF_GH_SEARCH_FILE="$T/search.json" BF_GH_API_FILE="$T/api.json" "$B" poll; grep -q "notify" "$BF_TEST_LOG" && tfail "must not nag twice for the same sha"
info=$("$B" info); [[ $(j '.updates|length' "$info") == 1 && $(j .enrolled "$info") == 1 ]] || tfail "info: $info"
pass "poll"

echo "== update --channel beta switches the installed clone; validation failure rolls back; stable returns"
"$B" update $ID --channel beta >/dev/null || tfail "update beta"
[[ $(git -C "$PL/$ID" rev-parse --abbrev-ref HEAD) == staging ]] || tfail "not on staging"
grep -q "fix" "$PL/$ID/lib/thing.sh" || tfail "beta content"
s=$("$B" status $ID); [[ $(j .channel "$s") == beta && $(j .updateAvailable "$s") == false ]] || tfail "channel after update: $s"
"$B" update $ID --channel beta | grep -q "already on staging" || tfail "idempotent"
# a broken beta must be rolled back
git -C "$SRC" switch -q staging && touch "$SRC/BREAK" && git -C "$SRC" add -A && git -C "$SRC" commit -qm "broken" && git -C "$SRC" push -q origin staging && git -C "$SRC" switch -q main
prev=$(git -C "$PL/$ID" rev-parse HEAD)
"$B" update $ID --channel beta >/dev/null 2>&1 && tfail "broken beta must fail"
[[ $(git -C "$PL/$ID" rev-parse HEAD) == "$prev" && ! -f $PL/$ID/BREAK ]] || tfail "rollback"
"$B" update $ID --channel stable >/dev/null || tfail "back to stable"
[[ $(git -C "$PL/$ID" rev-parse --abbrev-ref HEAD) == main ]] || tfail "not on main"
echo dirty >>"$PL/$ID/Panel.qml"; "$B" update $ID --channel beta >/dev/null 2>&1 && tfail "dirty clone must refuse"; git -C "$PL/$ID" checkout -q Panel.qml
pass "update / rollback / stable / dirty guard"

echo "== confirm posts a verdict"
: >"$BF_TEST_LOG"; "$B" confirm $ID 42 --works >/dev/null || tfail confirm
grep -q "gh issue comment 42 -R modpunk/test-plugin --body-file" "$BF_TEST_LOG" || tfail "comment"
r=$(jq -c 'select(.issue==42)' "$XDG_STATE_HOME/omarchy-beta-feedback/reports.jsonl"); [[ $(j .confirmed "$r") == works ]] || tfail "confirmed recorded"
pass "confirm"

echo "== author: sync → inbox json → approve → repair with the stub agent → PR → fixed → promote"
cat >"$T/api2.json" <<A
[{"number":42,"title":"Launch does nothing","state":"open","labels":[{"name":"beta-feedback"}],"updated_at":"2026-09-09T00:00:00Z","html_url":"https://github.com/modpunk/test-plugin/issues/42","body":"Clicked twice.\n\n<!-- beta-feedback kind=bug reporter=bf-abc12345 bundle=x plugin=test.plugin -->"},
 {"number":43,"title":"Add dark icons","state":"open","labels":[{"name":"beta-feedback"},{"name":"approved"}],"updated_at":"2026-09-09T00:00:00Z","html_url":"https://github.com/modpunk/test-plugin/issues/43","body":"y"}]
A
git -C "$SRC" switch -q staging && git -C "$SRC" reset -q --hard HEAD~1 && git -C "$SRC" push -q -f origin staging && git -C "$SRC" switch -q main
q=$(BF_GH_API_FILE="$T/api2.json" "$B" author inbox --json) || tfail "inbox json"
q=$(jq -c '[.[] | select(.number==42)]' <<<"$q")
[[ $(j '.[0].number' "$q") == 42 && $(j '.[0].status' "$q") == new && $(j '.[0].plugin' "$q") == test.plugin && $(j '.[0].reporter' "$q") == bf-abc12345 ]] || tfail "queue: $q"
"$B" author approve modpunk/test-plugin 42 >/dev/null || tfail approve
grep -q "gh issue edit 42 -R modpunk/test-plugin --add-label approved" "$BF_TEST_LOG" || tfail "approve label"
: >"$BF_TEST_LOG"
"$B" author repair modpunk/test-plugin 42 --merge >/dev/null 2>&1 || { tail -n 20 "$BF_TEST_LOG"; tfail "repair"; }
grep -q "claude -p --permission-mode acceptEdits" "$BF_TEST_LOG" || tfail "claude invoked"
grep -q "UNTRUSTED" "$T/claude-prompt.md" && grep -q "Clicked twice" "$T/claude-prompt.md" && grep -q 'tests/run.sh' "$T/claude-prompt.md" || tfail "prompt rendering"
wt="$XDG_STATE_HOME/omarchy-beta-feedback/work/modpunk_test-plugin-42"
git -C "$wt" log -1 --format=%s | grep -q "Fix #42" || tfail "commit"
git -C "$UP" show-ref --verify --quiet refs/heads/fix/issue-42 || tfail "branch pushed"
grep -q "gh pr create -R modpunk/test-plugin --base staging --head fix/issue-42" "$BF_TEST_LOG" || tfail "pr"
grep -q "gh issue edit 42 -R modpunk/test-plugin --add-label fixed-in-beta" "$BF_TEST_LOG" || tfail "fixed label"
q=$("$B" author inbox --json --no-sync); [[ $(jq -r '.[] | select(.number==42) | .status' <<<"$q") == fixed-in-beta ]] || tfail "status after repair: $q"
: >"$BF_TEST_LOG"; BF_AGENT_NOOP=1 BF_GH_API_FILE="$T/api2.json" "$B" author repair modpunk/test-plugin 43 --no-push >/dev/null 2>&1 && tfail "noop agent must fail"
q=$("$B" author inbox --json --no-sync); [[ $(jq -r '.[] | select(.number==43) | .status' <<<"$q") == approved ]] || tfail "noop leaves status approved: $q"
: >"$BF_TEST_LOG"; "$B" author promote modpunk/test-plugin 42 >/dev/null || tfail promote
grep -q "gh pr create -R modpunk/test-plugin --base main --head staging" "$BF_TEST_LOG" || tfail "release pr"
grep -q "gh issue edit 42 -R modpunk/test-plugin --add-label released" "$BF_TEST_LOG" || tfail "released label"
pass "author loop"

echo "== validator-friendly tree: no symlinks, manifest ok"
[[ -z $(find "$ROOT" -path "$ROOT/.git" -prune -o -type l -print) ]] || tfail "symlink in tree"
jq -e '.id=="fans.omarchy.beta-feedback" and .entryPoints.barWidget=="Panel.qml"' "$ROOT/manifest.json" >/dev/null || tfail manifest
cmp -s "$ROOT/sdk/BetaFeedback.qml" "$ROOT/BetaFeedback.qml" || tfail "root BetaFeedback.qml must mirror sdk/"
pass "tree"
echo "All tests passed."
