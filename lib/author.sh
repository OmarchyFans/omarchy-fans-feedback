#!/bin/bash
# Author side: enrolling your own repos, the triage queue (SQLite, synced from
# GitHub issue labels), the agent repair step, and promotion to main.
#
# Queue statuses: new → approved → repairing → pr-open → fixed-in-beta →
# confirmed → released, or rejected. Labels on GitHub are the source of truth
# for everything except repairing/pr-open (local, transient).

BF_REPOS="$BF_CONF/author-repos.json"   # { "owner/name": { "dir": "/path", "plugin": "id" } }
BF_DB="$BF_STATE/author.db"

repos_all() { json_file_or "$BF_REPOS" '{}'; }
repo_dir() { repos_all | jq -r --arg r "$1" '.[$r].dir // empty'; }
repo_slug_of_dir() { # repo_slug_of_dir <dir>
  local url; url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
  sed -nE 's#^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)([^/]+/[^/]+?)(\.git)?/?$#\2#p' <<<"$url"
}
repo_cfg() { # repo_cfg <slug> <jq> <default>
  local d; d=$(repo_dir "$1")
  if [[ -n $d && -f $d/.beta-feedback.json ]]; then jq -r --arg x "$3" "$2 // \$x" "$d/.beta-feedback.json"; else printf '%s' "$3"; fi
}

db() { sqlite3 -batch "$BF_DB" "$@"; }
db_init() {
  ensure_state
  db "CREATE TABLE IF NOT EXISTS issues (
        repo TEXT, number INTEGER, title TEXT, state TEXT, labels TEXT, status TEXT,
        plugin TEXT, kind TEXT, reporter TEXT, url TEXT, body TEXT, updated_at TEXT,
        confirmed TEXT, pr_url TEXT, note TEXT, PRIMARY KEY (repo, number));"
}
sq() { printf "%s" "${1//\'/\'\'}"; }   # SQL string escape

# ---- init ----------------------------------------------------------------------
author_init() { # author_init [repo-dir] [--push]
  local dir=${1:-.} push=0; [[ ${1:-} == --push ]] && { dir=.; push=1; }; [[ ${2:-} == --push ]] && push=1
  dir=$(cd -- "$dir" && pwd) || fail "no such dir"
  [[ -f $dir/manifest.json ]] || fail "$dir has no manifest.json (is it an Omarchy plugin?)"
  git -C "$dir" rev-parse >/dev/null 2>&1 || fail "$dir is not a git repo"
  local slug id stable beta
  slug=$(repo_slug_of_dir "$dir") || slug=""
  id=$(jq -r .id "$dir/manifest.json")
  [[ -n $slug ]] || slug=$(ui_input "GitHub repo (owner/name)" "modpunk/$(basename "$dir")") || fail "need a repo"
  stable=$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##'); [[ -n $stable ]] || stable=main
  beta=staging

  # 1. per-repo config (read by the end user's CLI from the installed clone)
  if [[ ! -f $dir/.beta-feedback.json ]]; then
    jq -n --arg r "$slug" --arg s "$stable" --arg b "$beta" \
      '{repo:$r, stableBranch:$s, betaBranch:$b, labels:["beta-feedback","approved","fixed-in-beta","released","wontfix"], test:""}' >"$dir/.beta-feedback.json"
    info "wrote .beta-feedback.json (set \"test\" to your test command, e.g. tests/run.sh)"
  else info ".beta-feedback.json already present"; fi

  # 2. the vendored SDK
  if cmp -s "$BF_ROOT/sdk/BetaFeedback.qml" "$dir/BetaFeedback.qml" 2>/dev/null; then info "BetaFeedback.qml is current"
  else cp -f "$BF_ROOT/sdk/BetaFeedback.qml" "$dir/BetaFeedback.qml"; info "vendored BetaFeedback.qml"; fi

  # 3. staging branch
  if git -C "$dir" show-ref --verify --quiet "refs/heads/$beta"; then info "branch $beta exists"
  else run git -C "$dir" branch "$beta" "$stable" && info "created branch $beta from $stable"; fi

  # 4. labels (needs gh + push rights; harmless to re-run)
  if gh_ready; then
    local l; for l in "beta-feedback:E99695:End-user beta report" "approved:0E8A16:Approved for repair" \
                      "fixed-in-beta:1D76DB:Fix is on the beta branch" "released:5319E7:Released to stable" "wontfix:FFFFFF:Will not fix"; do
      IFS=: read -r name color desc <<<"$l"
      run gh label create "$name" -R "$slug" --color "$color" --description "$desc" --force >/dev/null 2>&1 || warn "could not create label $name"
    done
    info "labels ensured on $slug"
  else warn "gh is not authenticated: create the labels beta-feedback/approved/fixed-in-beta/released/wontfix yourself"; fi
  (( push )) && run git -C "$dir" push -u origin "$beta"

  # 5. register locally
  json_write "$BF_REPOS" "$(repos_all | jq --arg r "$slug" --arg d "$dir" --arg id "$id" '.[$r] = {dir:$d, plugin:$id}')"
  db_init
  hr; say "Add this inside your KeyboardPanel (a direct child, next to PanelKeyCatcher):"
  say ""; say "    BetaFeedback { pluginId: root.moduleName; opened: panel.open }"
  say ""; say "Commit BetaFeedback.qml and .beta-feedback.json, push $beta (git push -u origin $beta), and you are enrolled."
}

# ---- sync + queue -------------------------------------------------------------------
author_sync() {
  db_init
  local slug issues
  for slug in $(repos_all | jq -r 'keys[]'); do
    issues=$(gh_issues_fetch "$slug") || continue
    jq -c '.[]' <<<"$issues" | while read -r i; do
      local n title state labels url body kind reporter plugin status
      n=$(jq -r .number <<<"$i"); title=$(jq -r .title <<<"$i"); state=$(jq -r .state <<<"$i")
      labels=$(jq -r '.labels | join(",")' <<<"$i"); url=$(jq -r .html_url <<<"$i"); body=$(jq -r '.body // ""' <<<"$i")
      kind=$(sed -nE 's/.*beta-feedback kind=([a-z]+).*/\1/p' <<<"$body" | head -n1)
      reporter=$(sed -nE 's/.*reporter=(bf-[0-9a-f]+).*/\1/p' <<<"$body" | head -n1)
      plugin=$(sed -nE 's/.*plugin=([A-Za-z0-9._-]+).*/\1/p' <<<"$body" | head -n1)
      status=$(label_status "$labels" "$state")
      db "INSERT INTO issues (repo,number,title,state,labels,status,plugin,kind,reporter,url,body,updated_at)
          VALUES ('$(sq "$slug")',$n,'$(sq "$title")','$state','$(sq "$labels")','$status','$(sq "$plugin")','$kind','$reporter','$(sq "$url")','$(sq "$body")','$(jq -r .updated_at <<<"$i")')
          ON CONFLICT(repo,number) DO UPDATE SET title=excluded.title, state=excluded.state, labels=excluded.labels,
            url=excluded.url, body=excluded.body, updated_at=excluded.updated_at,
            status=CASE WHEN issues.status IN ('repairing','pr-open') AND excluded.status IN ('new','approved') THEN issues.status ELSE excluded.status END;"
      # reporter verdicts arrive as comments on fixed-in-beta issues
      if [[ $status == fixed-in-beta ]] && gh_ready; then
        local v; v=$(gh api "repos/$slug/issues/$n/comments" 2>/dev/null | jq -r '[.[] | .body | capture("beta-feedback confirmed=(?<v>works|broken)") | .v] | last // empty')
        [[ -n $v ]] && db "UPDATE issues SET confirmed='$v', status=CASE WHEN '$v'='works' THEN 'confirmed' ELSE status END WHERE repo='$(sq "$slug")' AND number=$n;"
      fi
    done
  done
}
label_status() { # label_status <labels-csv> <state>
  case ",$1," in
    *,released,*) echo released ;; *,fixed-in-beta,*) echo fixed-in-beta ;; *,approved,*) echo approved ;;
    *,wontfix,*) echo rejected ;; *) [[ $2 == closed ]] && echo closed || echo new ;;
  esac
}
queue_json() { db -json "SELECT repo,number,title,state,labels,status,plugin,kind,reporter,url,confirmed,pr_url,updated_at FROM issues ORDER BY CASE status WHEN 'confirmed' THEN 0 WHEN 'new' THEN 1 WHEN 'approved' THEN 2 WHEN 'fixed-in-beta' THEN 3 ELSE 9 END, updated_at DESC;" | { read -r x; [[ -n $x ]] && { printf '%s' "$x"; cat; } || printf '[]'; }; }

author_mark() { # author_mark approve|reject <repo> <number> [--note text]
  local what=$1 slug=$2 n=$3
  [[ $n =~ ^[0-9]+$ ]] || fail "issue number required"
  db_init
  case "$what" in
    approve) run gh issue edit "$n" -R "$slug" --add-label approved >/dev/null && db "UPDATE issues SET status='approved' WHERE repo='$(sq "$slug")' AND number=$n;" ;;
    reject)  run gh issue edit "$n" -R "$slug" --add-label wontfix >/dev/null; run gh issue close "$n" -R "$slug" -c "Thanks for the report. This one will not be changed." >/dev/null
             db "UPDATE issues SET status='rejected' WHERE repo='$(sq "$slug")' AND number=$n;" ;;
  esac
  say "#$n: $what"
}

author_inbox() { # author_inbox [--json] [--no-sync]
  local json=0 sync=1; for a in "$@"; do [[ $a == --json ]] && json=1; [[ $a == --no-sync ]] && sync=0; done; (( JSON )) && json=1
  db_init; (( sync )) && author_sync
  if (( json )); then queue_json | jq '.'; return 0; fi
  [[ $(repos_all | jq length) -gt 0 ]] || fail "no repos registered; run: omarchy-beta-feedback author init <repo-dir>"
  while true; do
    local rows pick slug n
    rows=$(queue_json | jq -r '.[] | "#\(.number)\t\(.status)\t\(.kind // "?")\t\(.title | .[0:60])\t\(.repo)"')
    [[ -n $rows ]] || { say "Inbox empty."; return 0; }
    pick=$(ui_choose "Beta feedback inbox  (Esc to quit)" "${rows//$'\t'/  }"$'\n'"quit" ) || return 0
    [[ $pick == quit ]] && return 0
    n=${pick#\#}; n=${n%% *}; slug=${pick##* }
    local act; act=$(ui_choose "#$n — what now?" "show" "approve" "repair (agent)" "promote to main" "reject" "open in browser" "back") || continue
    case "$act" in
      show) db "SELECT body FROM issues WHERE repo='$(sq "$slug")' AND number=$n;" >"$BF_STATE/.show.md"; ui_pager "$BF_STATE/.show.md" ;;
      approve) author_mark approve "$slug" "$n" ;;
      reject) author_mark reject "$slug" "$n" ;;
      "repair (agent)") author_repair "$slug" "$n" ;;
      "promote to main") author_promote "$slug" "$n" ;;
      "open in browser") xdg-open "$(db "SELECT url FROM issues WHERE repo='$(sq "$slug")' AND number=$n;")" >/dev/null 2>&1 & ;;
    esac
  done
}

# ---- repair -------------------------------------------------------------------
author_repair() { # author_repair <repo> <number> [--agent name] [--merge] [--no-push]
  local slug=$1 n=$2 agent="" merge=0 push=1; shift 2 || fail "repair needs <repo> <number>"
  while (($#)); do case "$1" in --agent) agent=$2; shift ;; --merge) merge=1 ;; --no-push) push=0 ;; *) fail "repair: unknown option $1" ;; esac; shift; done
  [[ $n =~ ^[0-9]+$ ]] || fail "issue number required"
  db_init
  local dir beta title body plugin test wt branch prompt
  dir=$(repo_dir "$slug"); [[ -n $dir ]] || fail "$slug is not registered (author init)"
  beta=$(repo_cfg "$slug" .betaBranch staging); test=$(repo_cfg "$slug" .test "")
  [[ -z $test && -x $dir/tests/run.sh ]] && test="tests/run.sh"
  title=$(db "SELECT title FROM issues WHERE repo='$(sq "$slug")' AND number=$n;")
  [[ -n $title ]] || { author_sync; title=$(db "SELECT title FROM issues WHERE repo='$(sq "$slug")' AND number=$n;"); }
  [[ -n $title ]] || fail "issue #$n of $slug is not in the inbox"
  body=$(db "SELECT body FROM issues WHERE repo='$(sq "$slug")' AND number=$n;")
  plugin=$(db "SELECT plugin FROM issues WHERE repo='$(sq "$slug")' AND number=$n;")
  [[ -n $agent ]] || agent=$(config_get .agent claude)

  branch="fix/issue-$n"; wt="$BF_STATE/work/${slug//\//_}-$n"
  git -C "$dir" fetch --quiet origin "$beta" 2>/dev/null || true
  local base="origin/$beta"; git -C "$dir" rev-parse --verify -q "$base" >/dev/null || base=$beta
  if [[ -d $wt ]]; then git -C "$wt" checkout -q "$branch" 2>/dev/null || true
  else run git -C "$dir" worktree add -q -B "$branch" "$wt" "$base" || fail "could not create worktree at $wt"; fi

  prompt="$wt/.beta-feedback-prompt.md"
  render_prompt "$n" "$slug" "$title" "$body" "$plugin" "$test" >"$prompt"
  db "UPDATE issues SET status='repairing' WHERE repo='$(sq "$slug")' AND number=$n;"
  say "Running agent '$agent' in $wt …"
  if ! agent_run "$agent" "$wt" "$prompt"; then
    db "UPDATE issues SET status='approved', note='agent failed' WHERE repo='$(sq "$slug")' AND number=$n;"
    fail "agent run failed; worktree kept at $wt"
  fi
  rm -f "$prompt"
  if [[ -z $(git -C "$wt" status --porcelain) && $(git -C "$wt" rev-parse HEAD) == $(git -C "$wt" rev-parse "$base") ]]; then
    db "UPDATE issues SET status='approved', note='agent made no change' WHERE repo='$(sq "$slug")' AND number=$n;"
    fail "the agent changed nothing; worktree kept at $wt"
  fi
  if [[ -n $test ]]; then
    say "Running tests: $test"
    (cd "$wt" && bash -c "$test") || { db "UPDATE issues SET status='approved', note='tests failed' WHERE repo='$(sq "$slug")' AND number=$n;"; fail "tests failed; worktree kept at $wt"; }
  fi
  if [[ -n $(git -C "$wt" status --porcelain) ]]; then
    run git -C "$wt" add -A
    run git -C "$wt" -c user.name="${GIT_AUTHOR_NAME:-beta-feedback}" -c user.email="${GIT_AUTHOR_EMAIL:-beta-feedback@localhost}" \
      commit -q -m "Fix #$n: $title" -m "Repaired by omarchy-beta-feedback ($agent) from an end-user beta report." || fail "commit failed"
  fi
  (( push )) || { say "Committed on $branch in $wt (not pushed)."; return 0; }
  run git -C "$wt" push -q -u origin "$branch" || fail "push failed"
  local pr; pr=$(run gh pr create -R "$slug" --base "$beta" --head "$branch" --title "Fix #$n: $title" \
        --body "Closes nothing yet: this lands on \`$beta\` for beta testing. Fixes the end-user report #$n. Generated by omarchy-beta-feedback ($agent); review before merging." 2>/dev/null) || pr=""
  db "UPDATE issues SET status='pr-open', pr_url='$(sq "$pr")' WHERE repo='$(sq "$slug")' AND number=$n;"
  say "PR opened: ${pr:-(see gh)}"
  if (( merge )); then
    run gh pr merge -R "$slug" --squash --auto "$branch" >/dev/null 2>&1 || run gh pr merge -R "$slug" --squash "$branch" >/dev/null 2>&1 || warn "could not merge; do it on GitHub"
    author_mark_fixed "$slug" "$n"
  else
    say "Merge the PR, then run: omarchy-beta-feedback author fixed $slug $n   (or use --merge next time)"
  fi
}
author_mark_fixed() { # after the PR is on the beta branch
  local slug=$1 n=$2 beta plugin; beta=$(repo_cfg "$slug" .betaBranch staging); plugin=$(db "SELECT plugin FROM issues WHERE repo='$(sq "$slug")' AND number=$n;")
  local f; f=$(mktemp); printf 'A fix is on the `%s` branch. If you are enrolled in the beta, the Beta Feedback bar chip will offer **Update now**; otherwise run:\n\n```\nomarchy-beta-feedback update %s --channel beta\n```\n\nThen tell us with **It works** / **Still broken** in the panel (or a comment here).\n' "$beta" "$plugin" >"$f"
  run gh issue edit "$n" -R "$slug" --add-label fixed-in-beta --remove-label approved >/dev/null 2>&1 || true
  run gh issue comment "$n" -R "$slug" --body-file "$f" >/dev/null 2>&1 || true; rm -f "$f"
  db "UPDATE issues SET status='fixed-in-beta' WHERE repo='$(sq "$slug")' AND number=$n;"
}

render_prompt() { # render_prompt <n> <slug> <title> <body> <plugin> <test>
  local t; t=$(cat "$BF_ROOT/templates/repair-prompt.md")
  t=${t//\{\{ISSUE\}\}/$1}; t=${t//\{\{REPO\}\}/$2}; t=${t//\{\{TITLE\}\}/$3}; t=${t//\{\{PLUGIN\}\}/$5}; t=${t//\{\{TEST\}\}/${6:-"(no test command configured)"}}
  t=${t//\{\{BODY\}\}/$4}
  printf '%s\n' "$t"
}

# ---- promote -------------------------------------------------------------------
author_promote() { # author_promote <repo> [numbers...] [--merge] [--bump patch|minor]
  local slug=$1 merge=0 bump="" nums=(); shift || fail "promote needs <repo>"
  while (($#)); do case "$1" in --merge) merge=1 ;; --bump) bump=$2; shift ;; *) nums+=("$1") ;; esac; shift; done
  db_init
  local dir stable beta; dir=$(repo_dir "$slug"); [[ -n $dir ]] || fail "$slug is not registered"
  stable=$(repo_cfg "$slug" .stableBranch main); beta=$(repo_cfg "$slug" .betaBranch staging)
  if [[ -n $bump ]]; then
    local wt="$BF_STATE/work/${slug//\//_}-release" v nv
    [[ -d $wt ]] || run git -C "$dir" worktree add -q "$wt" "$beta" || fail "worktree failed"
    run git -C "$wt" pull -q --ff-only origin "$beta" || true
    v=$(jq -r .version "$wt/manifest.json"); IFS=. read -r a b c <<<"$v"
    case "$bump" in patch) nv="$a.$b.$((c+1))" ;; minor) nv="$a.$((b+1)).0" ;; major) nv="$((a+1)).0.0" ;; *) fail "--bump patch|minor|major" ;; esac
    if (( ! BF_DRY_RUN )); then jq --arg v "$nv" '.version=$v' "$wt/manifest.json" >"$wt/.m" && mv "$wt/.m" "$wt/manifest.json"; fi
    run git -C "$wt" commit -qam "Release $nv" && run git -C "$wt" push -q origin "$beta" || fail "could not push version bump"
    say "Bumped $v → $nv on $beta"
  fi
  local list=""; for n in "${nums[@]}"; do list+="#$n "; done
  local pr; pr=$(run gh pr create -R "$slug" --base "$stable" --head "$beta" --title "Release: ${list:-beta fixes}" \
        --body "Promotes tested beta fixes to \`$stable\`. Resolves: ${list:-see $beta}. Generated by omarchy-beta-feedback." 2>/dev/null) || pr=""
  say "Release PR: ${pr:-(exists or failed; check gh)}"
  if (( merge )); then
    run gh pr merge -R "$slug" --merge "$beta" >/dev/null 2>&1 || warn "merge failed; merge on GitHub then re-run without --merge to label"
  fi
  local n; for n in "${nums[@]}"; do
    run gh issue edit "$n" -R "$slug" --add-label released --remove-label fixed-in-beta >/dev/null 2>&1 || true
    run gh issue comment "$n" -R "$slug" --body "Released on \`$stable\`. The stable channel now has this fix: run \`omarchy plugin update\` (or **Back to stable** in the Beta Feedback panel). Thank you for testing! 🎉" >/dev/null 2>&1 || true
    run gh issue close "$n" -R "$slug" >/dev/null 2>&1 || true
    db "UPDATE issues SET status='released' WHERE repo='$(sq "$slug")' AND number=$n;"
  done
}
