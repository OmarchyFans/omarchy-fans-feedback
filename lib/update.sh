#!/bin/bash
# End-user side of the loop after a report is filed: polling GitHub for the
# author's progress, telling the user a fix is ready, switching the plugin
# clone between the stable and beta branches, and confirming the result.

# ---- channel switch ---------------------------------------------------------
# `omarchy plugin update` fetches origin HEAD and fast-forwards; it knows nothing
# about branches. We track the branch explicitly (never FETCH_HEAD, which the
# stock updater clobbers) and validate before keeping the checkout. A git
# checkout inside ~/.config/omarchy/plugins makes the shell reload its plugins.
cmd_update() { # cmd_update <pluginId> --channel beta|stable
  local id=${1:-} channel=stable branch prev prevsha dir
  shift || true
  while (($#)); do case "$1" in --channel) channel=$2; shift ;; *) fail "update: unknown option $1" ;; esac; shift; done
  require_plugin_id "$id"; ensure_state
  dir=$(plugin_dir "$id"); [[ -d $dir/.git ]] || fail "$id is not a git-managed plugin"
  case "$channel" in
    beta)   branch=$(plugin_cfg "$id" .betaBranch staging) ;;
    stable) branch=$(plugin_cfg "$id" .stableBranch main) ;;
    *) fail "--channel must be beta or stable" ;;
  esac
  [[ -z $(git -C "$dir" status --porcelain 2>/dev/null) ]] || fail "$id has local changes in $dir; not switching"
  prev=$(git -C "$dir" rev-parse --abbrev-ref HEAD); prevsha=$(git -C "$dir" rev-parse HEAD)
  run git -C "$dir" fetch --quiet origin "+refs/heads/$branch:refs/remotes/origin/$branch" || fail "fetch of $branch failed"
  if (( BF_DRY_RUN )); then info "[dry-run] would switch $id to $branch"; return 0; fi
  if [[ $prev == "$branch" ]]; then
    if [[ $(git -C "$dir" rev-parse HEAD) == $(git -C "$dir" rev-parse "origin/$branch") ]]; then
      say "$id is already on $branch at the latest commit."; enroll_note_installed "$id" "$channel"; return 0
    fi
    git -C "$dir" merge --ff-only "origin/$branch" >/dev/null 2>&1 || fail "cannot fast-forward $branch"
  else
    git -C "$dir" switch -C "$branch" --track "origin/$branch" >/dev/null 2>&1 || fail "could not switch to $branch"
  fi
  if have omarchy-plugin-validate && ! omarchy-plugin-validate "$dir" >/dev/null 2>&1; then
    git -C "$dir" switch -C "$prev" "$prevsha" >/dev/null 2>&1 || git -C "$dir" checkout -q "$prevsha"
    notify "Update of $id failed validation" "Rolled back to $prev"
    fail "$branch of $id failed omarchy-plugin-validate; rolled back to $prev"
  fi
  enroll_note_installed "$id" "$channel"
  say "$id is now on $branch ($(git -C "$dir" rev-parse --short=12 HEAD)). The shell reloads plugins automatically."
  notify "$id updated" "Now running the $channel version ($branch)"
}

enroll_note_installed() { # enroll_note_installed <pluginId> <channel>
  local e; e=$(enroll_get "$1"); [[ $e == null ]] && return 0
  enroll_set "$1" "$(jq -c --arg ch "$2" --arg sha "$(plugin_sha "$1")" \
    '.channel=$ch | .installedSha=$sha | .updateAvailable=false | .updateSha=""' <<<"$e")"
}

# ---- polling -----------------------------------------------------------------
# For every enrolled plugin with a GitHub repo: refresh the state of the issues
# this install filed, then decide whether to nudge the user.
cmd_poll() {
  local all=0; [[ ${1:-} == --all ]] && all=1
  ensure_state
  local id status repo
  while IFS=$'\t' read -r id status; do
    [[ $status == enrolled || $all == 1 ]] || continue
    repo=$(plugin_repo "$id"); [[ -n $repo ]] || continue
    poll_plugin "$id" "$repo"
  done < <(enroll_all | jq -r 'to_entries[] | "\(.key)\t\(.value.status)"')
}

poll_plugin() { # poll_plugin <pluginId> <owner/repo>
  local id=$1 repo=$2 issues mine
  mine=$(reports_for "$id")
  [[ $(jq length <<<"$mine") -gt 0 ]] || return 0

  # Browser-submitted reports have no number yet: find them by the hidden marker.
  local bundle found
  while read -r bundle; do
    [[ -n $bundle ]] || continue
    found=$(gh_issues_search_marker "$repo" "bundle=$bundle" | jq -c '.[0] // empty')
    [[ -n $found ]] && report_update "$bundle" ".issue=$(jq .number <<<"$found") | .url=$(jq .html_url <<<"$found") | .status=\"open\""
  done < <(jq -r '.[] | select(.issue == null and .status == "browser") | .bundle' <<<"$mine")

  issues=$(gh_issues_fetch "$repo") || issues='[]'
  [[ $(jq length <<<"$issues") -gt 0 ]] || return 0
  local n labels state
  while IFS=$'\t' read -r bundle n; do
    [[ -n $n && $n != null ]] || continue
    labels=$(jq -c --argjson n "$n" '.[] | select(.number == $n) | .labels' <<<"$issues"); [[ -n $labels ]] || continue
    state=$(jq -r --argjson n "$n" '.[] | select(.number == $n) | .state' <<<"$issues")
    report_update "$bundle" ".labels=$labels | .state=\"$state\" | .status=(if ($labels|index(\"released\")) then \"released\" elif ($labels|index(\"fixed-in-beta\")) then \"fixed-in-beta\" elif ($labels|index(\"approved\")) then \"approved\" elif ($labels|index(\"wontfix\")) then \"wontfix\" elif \"$state\"==\"closed\" then \"closed\" else \"open\" end)"
  done < <(jq -r '.[] | select(.issue != null) | "\(.bundle)\t\(.issue)"' <<<"$mine")

  # Nudge: a fix is on the beta branch and we are not running it yet.
  mine=$(reports_for "$id")
  local e beta remote_sha; e=$(enroll_get "$id")
  if jq -e '.[] | select(.status == "fixed-in-beta")' <<<"$mine" >/dev/null; then
    beta=$(plugin_cfg "$id" .betaBranch staging)
    remote_sha=$(git -C "$(plugin_dir "$id")" ls-remote --quiet origin "refs/heads/$beta" 2>/dev/null | cut -c1-12)
    if [[ -n $remote_sha && $remote_sha != $(plugin_sha "$id") ]]; then
      enroll_set "$id" "$(jq -c --arg s "$remote_sha" '.updateAvailable=true | .updateSha=$s' <<<"$e")"
      if [[ $(jq -r '.notifiedSha // ""' <<<"$e") != "$remote_sha" ]]; then
        enroll_set "$id" "$(enroll_get "$id" | jq -c --arg s "$remote_sha" '.notifiedSha=$s')"
        notify "$id: a fix for your report is ready to test" "Click to update now, or later from the bug panel" \
          --exec "$BF_SELF" update "$id" --channel beta
      fi
    fi
  elif jq -e '.[] | select(.status == "released")' <<<"$mine" >/dev/null && [[ $(jq -r '.channel // "stable"' <<<"$e") == beta ]]; then
    if [[ $(jq -r '.notifiedRelease // ""' <<<"$e") != "$(today)" ]]; then
      enroll_set "$id" "$(jq -c --arg d "$(today)" '.notifiedRelease=$d' <<<"$e")"
      notify "$id: your fix is released" "Click to go back to the stable channel" \
        --exec "$BF_SELF" update "$id" --channel stable
    fi
  fi
}

# ---- confirmation ------------------------------------------------------------
cmd_confirm() { # cmd_confirm <pluginId> <issue> --works|--broken [--note text]
  local id=${1:-} n=${2:-} verdict="" note=""
  shift 2 || fail "confirm needs <pluginId> <issue>"
  while (($#)); do case "$1" in --works) verdict=works ;; --broken) verdict=broken ;; --note) note=$2; shift ;; *) fail "confirm: unknown option $1" ;; esac; shift; done
  require_plugin_id "$id"; [[ $n =~ ^[0-9]+$ ]] || fail "issue number required"
  [[ -n $verdict ]] || verdict=$(ui_choose "How did the beta go?" works broken) || fail "cancelled"
  local repo f; repo=$(plugin_repo "$id"); [[ -n $repo ]] || fail "no repo for $id"
  f=$(mktemp); {
    if [[ $verdict == works ]]; then printf 'Tested the beta (%s): the fix works for me. ✅\n' "$(plugin_sha "$id")"
    else printf 'Tested the beta (%s): still broken for me. ❌\n' "$(plugin_sha "$id")"; fi
    [[ -n $note ]] && printf '\n%s\n' "$note"
    printf '\n<!-- beta-feedback confirmed=%s reporter=%s -->\n' "$verdict" "$(reporter_id)"
  } >"$f"
  if gh_ready && gh_issue_comment "$repo" "$n" "$f"; then say "Posted your verdict on issue #$n."
  else
    have wl-copy && wl-copy <"$f" 2>/dev/null
    run xdg-open "$(issue_comment_url "$repo" "$n")" >/dev/null 2>&1 &
    say "Opened issue #$n; your comment text is on the clipboard — paste and post it."
  fi
  rm -f "$f"
  report_update_by_issue "$id" "$n" ".confirmed=\"$verdict\""
}
report_update_by_issue() { # <pluginId> <issue> <jq-update>
  [[ -s $BF_REPORTS ]] || return 0
  local tmp; tmp=$(mktemp "$BF_STATE/.tmp.XXXXXX")
  jq -c --arg id "$1" --argjson n "$2" "if .plugin == \$id and .issue == \$n then $3 else . end" "$BF_REPORTS" >"$tmp" && mv -f "$tmp" "$BF_REPORTS"
}

# ---- joinable betas ----------------------------------------------------------
# Installed plugins that are not enrolled: `beta` when their author runs a beta
# program (.beta-feedback.json with a repo), `source` when the plugin was
# installed from a git repo on this machine, so the user can set one up.
available_json() {
  local d id list='[]' st cfg repo origin src name
  for d in "$BF_PLUGINS"/*/; do
    d=${d%/}; id=${d##*/}
    [[ -f $d/manifest.json ]] && valid_plugin_id "$id" || continue
    [[ $id == fans.omarchy.beta-feedback ]] && continue
    st=$(enroll_get "$id" | jq -r '.status // "unknown"')
    [[ $st == enrolled ]] && continue
    cfg=false; [[ -f $d/.beta-feedback.json ]] && cfg=true
    repo=$(plugin_repo "$id")
    origin=$(git -C "$d" remote get-url origin 2>/dev/null || true)
    src=""; [[ $origin == /* && -e $origin/.git ]] && src=$origin
    name=$(jq -r '.name // .id // empty' "$d/manifest.json" 2>/dev/null)
    list=$(jq -c --arg id "$id" --arg name "${name:-$id}" --arg st "$st" --argjson cfg "$cfg" --arg repo "$repo" --arg src "$src" \
      '. + [{plugin: $id, name: $name, status: $st, beta: ($cfg and $repo != ""), repo: $repo, source: $src}]' <<<"$list")
  done
  printf '%s' "$list"
}

# ---- everything the bar panel needs, in one JSON ----------------------------
cmd_info() {
  ensure_state
  local ids id list='[]'
  ids=$(enroll_all | jq -r 'keys[]')
  for id in $ids; do
    list=$(jq -c --argjson s "$(cmd_status "$id")" '. + [$s]' <<<"$list")
  done
  jq -cn --arg r "$(reporter_id)" --argjson e "$list" --arg v "$BF_VERSION" \
     --argjson a "$(available_json)" --argjson dr "$(reports_for desktop)" --argjson rec "$(record_status --json)" \
    '{version:$v, reporter:$r, plugins:$e, available:$a, desktopReports:$dr, recording:$rec,
      updates:[$e[] | select(.updateAvailable)], enrolled:[$e[] | select(.status=="enrolled")] | length}'
}
