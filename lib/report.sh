#!/bin/bash
# Building and submitting a report. Called by the SDK as
#   omarchy-beta-feedback report --plugin ID --branch B --shot PNG --context JSON
# (detached, so we re-open ourselves in a floating terminal for the form).

# ---- diagnostics ------------------------------------------------------------
env_json() { # env_json <pluginId>
  local id=$1 dir; dir=$(plugin_dir "$id")
  local omarchy hypr qs theme monitors dirty
  omarchy=$(omarchy version 2>/dev/null | head -n1 || true)
  [[ -z $omarchy && -f /usr/share/omarchy/version ]] && omarchy=$(cat /usr/share/omarchy/version 2>/dev/null)
  hypr=$(hyprctl version -j 2>/dev/null | jq -r '.tag // .version // empty' 2>/dev/null || true)
  qs=$(quickshell --version 2>/dev/null | head -n1 || true)
  theme=$(basename "$(readlink -f "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/current/theme" 2>/dev/null)" 2>/dev/null || true)
  monitors=$(hyprctl monitors -j 2>/dev/null | jq -c '[.[] | {name, width, height, scale, refreshRate}]' 2>/dev/null || echo '[]')
  dirty=false; [[ -n $(git -C "$dir" status --porcelain 2>/dev/null) ]] && dirty=true
  jq -cn --arg id "$id" --arg v "$(plugin_version "$id")" --arg sha "$(plugin_sha "$id")" \
     --arg branch "$(plugin_branch "$id")" --argjson dirty "$dirty" --arg omarchy "${omarchy:-?}" \
     --arg hypr "${hypr:-?}" --arg qs "${qs:-?}" --arg theme "${theme:-?}" --argjson monitors "${monitors:-[]}" \
     --arg reporter "$(reporter_id)" --arg at "$(now_iso)" \
     '{plugin:$id, version:$v, sha:$sha, branch:$branch, dirty:$dirty, omarchy:$omarchy, hyprland:$hypr,
       quickshell:$qs, theme:$theme, monitors:$monitors, reporter:$reporter, at:$at}'
}

# Last shell log lines that mention the plugin, plus the tail (QML load errors).
shell_log() { # shell_log <pluginId>
  have journalctl || return 0
  local all; all=$(journalctl --user -t omarchy-shell -n 400 --no-pager -o cat 2>/dev/null | strip_ansi)
  [[ -n $all ]] || return 0
  { grep -F -- "$1" <<<"$all" | tail -n 60; echo "--- last 30 lines ---"; tail -n 30 <<<"$all"; } | grep -v '^$' | head -n 100
}

# ---- annotation ------------------------------------------------------------
annotate() { # annotate <in.png> <out.png>  (Enter saves; Escape keeps the raw grab)
  [[ -s $1 ]] || return 0
  if have tensaku; then
    tensaku -f "$1" -o "$2" --actions-on-enter save-to-file,exit --actions-on-escape exit --early-exit \
      --initial-tool arrow --disable-notifications >/dev/null 2>&1 || true
  fi
  [[ -s $2 ]] || cp -f "$1" "$2"
}

# ---- body ------------------------------------------------------------------
render_body() { # render_body <bundle-dir> <kind> <description>
  local b=$1 kind=$2 desc=$3 env; env=$(cat "$b/env.json")
  local id; id=$(jq -r .plugin <<<"$env")
  {
    printf '%s\n\n' "$desc"
    printf '| | |\n|---|---|\n'
    jq -r '"| Plugin | `\(.plugin)` \(.version) |",
           "| Commit | `\(.sha)` on `\(.branch)`\(if .dirty then " (local changes)" else "" end) |",
           "| Omarchy | \(.omarchy) |","| Hyprland | \(.hyprland) |","| Quickshell | \(.quickshell) |",
           "| Theme | \(.theme) |","| Monitors | \(.monitors | map("\(.name) \(.width)x\(.height)@\(.scale)") | join(", ")) |"' <<<"$env"
    if [[ -s $b/trace.json ]] && [[ $(jq 'length' "$b/trace.json") -gt 0 ]]; then
      printf '\n**Last clicks before the report** (oldest first)\n\n'
      jq -r '.[] | "- \(.b // 1 | if . == 2 then "right" elif . == 4 then "middle" else "left" end) click on `\(.at // "?")`"' "$b/trace.json"
    fi
    if [[ -s $b/shell.log ]]; then
      printf '\n<details><summary>Shell log excerpt</summary>\n\n```\n'; cat "$b/shell.log"; printf '```\n</details>\n'
    fi
    [[ -s $b/annotated.png ]] && printf '\n_Screenshot: pasted below by the reporter (it was copied to their clipboard)._\n'
    printf '\n<!-- beta-feedback kind=%s reporter=%s bundle=%s plugin=%s -->\n' "$kind" "$(jq -r .reporter <<<"$env")" "$(basename "$b")" "$id"
  }
}

# ---- the command -----------------------------------------------------------
cmd_report() {
  local id="" branch="" shot="" context="[]" kind="" title="" desc="" nopopup=0
  while (($#)); do
    case "$1" in
      --plugin) id=$2; shift ;; --branch) branch=$2; shift ;; --shot) shot=$2; shift ;;
      --context) context=$2; shift ;; --kind) kind=$2; shift ;; --title) title=$2; shift ;;
      --description) desc=$2; shift ;; --no-popup) nopopup=1 ;;
      *) fail "report: unknown option $1" ;;
    esac; shift
  done
  require_plugin_id "$id"; ensure_state
  [[ -d $(plugin_dir "$id") ]] || fail "plugin '$id' is not installed"

  # The SDK starts us detached; the form needs a terminal.
  if [[ -z ${BF_POPUP:-} && ! -t 0 && $nopopup == 0 ]]; then
    popup_reexec report --plugin "$id" --branch "$branch" --shot "$shot" --context "$context" ${kind:+--kind "$kind"}
  fi

  local b="$BF_BUNDLES/$(ts_id)-$id"; mkdir -p "$b"
  jq -c '.' <<<"$context" >"$b/trace.json" 2>/dev/null || printf '[]' >"$b/trace.json"
  env_json "$id" >"$b/env.json"
  shell_log "$id" >"$b/shell.log" || true
  if [[ -n $shot && -s $shot ]]; then
    mv -f "$shot" "$b/panel.png" 2>/dev/null || cp -f "$shot" "$b/panel.png"
    say "Annotate the screenshot (Enter saves, Escape keeps it as is)…"
    annotate "$b/panel.png" "$b/annotated.png"
  fi

  say ""; ui_style "Beta feedback for $id"
  [[ -n $kind ]]  || kind=$(ui_choose "What is this?" bug feature) || fail "cancelled"
  [[ -n $title ]] || title=$(ui_input "One-line title" "e.g. Launch button does nothing on second click") || fail "cancelled"
  [[ -n $title ]] || fail "a title is required"
  [[ -n $desc ]]  || desc=$(ui_write "What happened, what you expected (Ctrl+D when done)" "Steps, expectation, actual result") || desc=""

  render_body "$b" "$kind" "$desc" >"$b/body.md"
  printf '%s\n' "$title" >"$b/title.txt"
  local repo; repo=$(plugin_repo "$id")

  say ""; info "Everything that will be sent:"; ui_pager "$b/body.md"
  local choices=() how
  [[ -n $repo ]] && gh_ready && choices+=("Submit to github.com/$repo (gh)")
  [[ -n $repo ]] && choices+=("Open github.com/$repo in the browser")
  choices+=("Save the bundle only (nothing leaves this machine)")
  how=$(ui_choose "Send it how?" "${choices[@]}") || how=${choices[-1]}

  local rec url="" number=""
  rec=$(jq -cn --arg id "$id" --arg b "$(basename "$b")" --arg t "$title" --arg k "$kind" --arg repo "$repo" \
        --arg sha "$(plugin_sha "$id")" --arg at "$(now_iso)" \
        '{plugin:$id, bundle:$b, title:$t, kind:$k, repo:$repo, sha:$sha, at:$at, issue:null, url:"", status:"local"}')
  case "$how" in
    *"(gh)")
      url=$(gh_issue_create "$repo" "$title" "$b/body.md" "$BF_LABEL") || url=""
      if [[ -n $url ]]; then
        number=${url##*/}
        rec=$(jq -c --arg u "$url" --argjson n "$number" '.url=$u | .issue=$n | .status="open"' <<<"$rec")
        say "Filed $url"
      else
        warn "gh could not create the issue (label missing? not a collaborator?); opening the browser instead"
        how="browser"
      fi ;;
  esac
  if [[ $how == browser || $how == *"in the browser" ]]; then
    url=$(issue_new_url "$repo" "$title" "$b/body.md" "$BF_LABEL")
    rec=$(jq -c '.status="browser"' <<<"$rec")
    run xdg-open "$url" >/dev/null 2>&1 &
    say "Opened a prefilled issue in your browser. Press 'Submit new issue' there."
  fi
  if [[ -s $b/annotated.png && $how != *"bundle only"* ]]; then
    have wl-copy && wl-copy --type image/png <"$b/annotated.png" 2>/dev/null || true
    say "The annotated screenshot is on your clipboard: paste it (Ctrl+V) into the issue text."
    notify "Screenshot copied — paste it into the issue" "Ctrl+V in the GitHub issue box" \
      ${url:+--exec xdg-open "${rec:+$(jq -r '.url // empty' <<<"$rec")}"} 2>/dev/null || true
  fi
  report_append "$rec"
  say "Bundle saved at $b"
  [[ ${BF_POPUP:-0} == 1 ]] && read -rp "Press Enter to close…" _
  return 0
}
