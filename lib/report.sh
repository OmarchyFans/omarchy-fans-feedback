#!/bin/bash
# Building and submitting a report. Called by the SDK as
#   omarchy-beta-feedback report --plugin ID --branch B --shot PNG --context JSON
# (detached, so we re-open ourselves in a floating terminal for the form), and
# after a troubleshooting recording as
#   omarchy-beta-feedback report --bundle DIR [--plugin ID]
# where no --plugin means the report is about the Omarchy desktop itself.

# ---- diagnostics ------------------------------------------------------------
env_json() { # env_json <pluginId|"">   ("" = the Omarchy desktop itself)
  local id=$1 dir=""; [[ -n $id ]] && dir=$(plugin_dir "$id")
  local omarchy hypr qs theme monitors dirty
  omarchy=$(omarchy version 2>/dev/null | head -n1 || true)
  [[ -z $omarchy && -f /usr/share/omarchy/version ]] && omarchy=$(cat /usr/share/omarchy/version 2>/dev/null)
  hypr=$(hyprctl version -j 2>/dev/null | jq -r '.tag // .version // empty' 2>/dev/null || true)
  qs=$(quickshell --version 2>/dev/null | head -n1 || true)
  theme=$(basename "$(readlink -f "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/current/theme" 2>/dev/null)" 2>/dev/null || true)
  monitors=$(hyprctl monitors -j 2>/dev/null | jq -c '[.[] | {name, width, height, scale, refreshRate}]' 2>/dev/null || echo '[]')
  dirty=false; [[ -n $dir && -n $(git -C "$dir" status --porcelain 2>/dev/null) ]] && dirty=true
  jq -cn --arg id "$id" --arg v "$([[ -n $id ]] && plugin_version "$id")" --arg sha "$([[ -n $id ]] && plugin_sha "$id")" \
     --arg branch "$([[ -n $id ]] && plugin_branch "$id")" --argjson dirty "$dirty" --arg omarchy "${omarchy:-?}" \
     --arg hypr "${hypr:-?}" --arg qs "${qs:-?}" --arg theme "${theme:-?}" --argjson monitors "${monitors:-[]}" \
     --arg reporter "$(reporter_id)" --arg at "$(now_iso)" \
     '{plugin:$id, version:$v, sha:$sha, branch:$branch, dirty:$dirty, omarchy:$omarchy, hyprland:$hypr,
       quickshell:$qs, theme:$theme, monitors:$monitors, reporter:$reporter, at:$at}'
}

# Last shell log lines that mention the plugin, plus the tail (QML load errors).
# Without a plugin id, just the tail.
shell_log() { # shell_log <pluginId|"">
  have journalctl || return 0
  local all; all=$(journalctl --user -t omarchy-shell -n 400 --no-pager -o cat 2>/dev/null | strip_ansi)
  [[ -n $all ]] || return 0
  if [[ -z $1 ]]; then tail -n 60 <<<"$all" | grep -v '^$'; return 0; fi
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
    jq -r 'if .plugin == "" then "| Target | Omarchy desktop |" else
             "| Plugin | `\(.plugin)` \(.version) |",
             "| Commit | `\(.sha)` on `\(.branch)`\(if .dirty then " (local changes)" else "" end) |" end,
           "| Omarchy | \(.omarchy) |","| Hyprland | \(.hyprland) |","| Quickshell | \(.quickshell) |",
           "| Theme | \(.theme) |","| Monitors | \(.monitors | map("\(.name) \(.width)x\(.height)@\(.scale)") | join(", ")) |"' <<<"$env"
    if [[ -s $b/input.json ]]; then
      jq -r '"| Keyboard | \(.keyboard.layout // "?")\(if (.keyboard.variant // "") != "" then " (\(.keyboard.variant))" else "" end), options `\(.keyboard.options // "")` |",
             "| Input method | \(.inputMethod) |"' "$b/input.json"
    fi
    if [[ -s $b/trace.json ]] && [[ $(jq 'length' "$b/trace.json") -gt 0 ]]; then
      printf '\n**Last clicks before the report** (oldest first)\n\n'
      jq -r '.[] | "- \(.b // 1 | if . == 2 then "right" elif . == 4 then "middle" else "left" end) click on `\(.at // "?")`"' "$b/trace.json"
    fi
    if [[ -s $b/timeline.txt ]]; then
      printf '\n**Troubleshooting recording**'
      if [[ -s $b/summary.json ]]; then
        jq -r '" (\(.durationMs / 1000 | floor) s, \(.keys) key events\(if .lockPauses > 0 then ", key log paused while the screen was locked" else "" end))\n"' "$b/summary.json"
        jq -r 'if (.bindHits | length) > 0 then "Key presses that matched a Hyprland keybinding:\n\n" + (.bindHits | unique | map("- `\(.)`") | join("\n")) + "\n" else empty end' "$b/summary.json"
        jq -r 'if .video != "" then "_Video: `\(.video | split("/") | last)`, attached below by the reporter._" else empty end' "$b/summary.json"
      else
        printf '\n'
      fi
      printf '\n<details><summary>Key and event timeline</summary>\n\n```\n'; head -n 300 "$b/timeline.txt"; printf '```\n</details>\n'
    fi
    if [[ -s $b/shell.log ]]; then
      printf '\n<details><summary>Shell log excerpt</summary>\n\n```\n'; cat "$b/shell.log"; printf '```\n</details>\n'
    fi
    [[ -s $b/annotated.png ]] && printf '\n_Screenshot: pasted below by the reporter (it was copied to their clipboard)._\n'
    printf '\n<!-- beta-feedback kind=%s reporter=%s bundle=%s plugin=%s -->\n' "$kind" "$(jq -r .reporter <<<"$env")" "$(basename "$b")" "${id:-desktop}"
  }
}

# ---- the command -----------------------------------------------------------
cmd_report() {
  local id="" branch="" shot="" context="[]" kind="" title="" desc="" nopopup=0 bundle=""
  while (($#)); do
    case "$1" in
      --plugin) id=$2; shift ;; --branch) branch=$2; shift ;; --shot) shot=$2; shift ;;
      --context) context=$2; shift ;; --kind) kind=$2; shift ;; --title) title=$2; shift ;;
      --description) desc=$2; shift ;; --bundle) bundle=$2; shift ;; --no-popup) nopopup=1 ;;
      *) fail "report: unknown option $1" ;;
    esac; shift
  done
  ensure_state
  if [[ -n $bundle ]]; then
    bundle=$(readlink -f -- "$bundle") && [[ -d $bundle && $bundle == "$(readlink -f -- "$BF_BUNDLES")"/* ]] \
      || fail "report: --bundle must be a folder inside $BF_BUNDLES"
  fi
  if [[ -n $id || -z $bundle ]]; then
    require_plugin_id "$id"
    [[ -d $(plugin_dir "$id") ]] || fail "plugin '$id' is not installed"
  fi

  # The SDK starts us detached; the form needs a terminal.
  if [[ -z ${BF_POPUP:-} && ! -t 0 && $nopopup == 0 ]]; then
    popup_reexec report ${id:+--plugin "$id"} --branch "$branch" --shot "$shot" --context "$context" \
      ${kind:+--kind "$kind"} ${bundle:+--bundle "$bundle"}
  fi

  local b=$bundle
  if [[ -z $b ]]; then b="$BF_BUNDLES/$(ts_id)-$id"; mkdir -p "$b"; fi
  [[ -s $b/trace.json ]] || { jq -c '.' <<<"$context" >"$b/trace.json" 2>/dev/null || printf '[]' >"$b/trace.json"; }
  [[ -s $b/env.json ]] || env_json "$id" >"$b/env.json"
  shell_log "$id" >"$b/shell.log" || true
  if [[ -n $shot && -s $shot ]]; then
    mv -f "$shot" "$b/panel.png" 2>/dev/null || cp -f "$shot" "$b/panel.png"
    say "Annotate the screenshot (Enter saves, Escape keeps it as is)…"
    annotate "$b/panel.png" "$b/annotated.png"
  fi

  say ""; ui_style "Beta feedback for ${id:-the Omarchy desktop}"
  [[ -n $kind ]]  || kind=$(ui_choose "What is this?" bug feature) || fail "cancelled"
  [[ -n $title ]] || title=$(ui_input "One-line title" "e.g. Launch button does nothing on second click") || fail "cancelled"
  [[ -n $title ]] || fail "a title is required"
  [[ -n $desc ]]  || desc=$(ui_write "What happened, what you expected (Ctrl+D when done)" "Steps, expectation, actual result") || desc=""

  render_body "$b" "$kind" "$desc" >"$b/body.md"
  printf '%s\n' "$title" >"$b/title.txt"
  # Desktop reports go to Omarchy (or config.json "desktopRepo"), where our
  # labels do not exist, so none is sent.
  local repo label=$BF_LABEL
  if [[ -n $id ]]; then repo=$(plugin_repo "$id")
  else repo=$(config_get .desktopRepo omacom/omarchy); label=""; fi

  say ""; info "Everything that will be sent:"; ui_pager "$b/body.md"
  local choices=() how
  [[ -n $repo ]] && gh_ready && choices+=("Submit to github.com/$repo (gh)")
  [[ -n $repo ]] && choices+=("Open github.com/$repo in the browser")
  choices+=("Save the bundle only (nothing leaves this machine)")
  how=$(ui_choose "Send it how?" "${choices[@]}") || how=${choices[-1]}

  local rec url="" number=""
  rec=$(jq -cn --arg id "${id:-desktop}" --arg b "$(basename "$b")" --arg t "$title" --arg k "$kind" --arg repo "$repo" \
        --arg sha "$([[ -n $id ]] && plugin_sha "$id")" --arg at "$(now_iso)" \
        '{plugin:$id, bundle:$b, title:$t, kind:$k, repo:$repo, sha:$sha, at:$at, issue:null, url:"", status:"local"}')
  case "$how" in
    *"(gh)")
      url=$(gh_issue_create "$repo" "$title" "$b/body.md" "$label") || url=""
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
    url=$(issue_new_url "$repo" "$title" "$b/body.md" "$label")
    rec=$(jq -c --arg u "$url" '.status="browser" | .url=$u' <<<"$rec")
    run xdg-open "$url" >/dev/null 2>&1 &
    say "Opened a prefilled issue in your browser. Press 'Submit new issue' there."
  fi
  if [[ -s $b/annotated.png && $how != *"bundle only"* ]]; then
    have wl-copy && wl-copy --type image/png <"$b/annotated.png" 2>/dev/null || true
    say "The annotated screenshot is on your clipboard: paste it (Ctrl+V) into the issue text."
    notify "Screenshot copied — paste it into the issue" "Ctrl+V in the GitHub issue box" \
      ${url:+--exec xdg-open "${rec:+$(jq -r '.url // empty' <<<"$rec")}"} 2>/dev/null || true
  fi
  local video=""; [[ -s $b/summary.json ]] && video=$(jq -r '.video // ""' "$b/summary.json")
  if [[ -n $video && -f $video && $how != *"bundle only"* ]]; then
    say "Attach the video: drag $video into the issue text."
    notify "Attach the recording to the issue" "Drag $(basename "$video") into the GitHub issue box" \
      --exec xdg-open "$(dirname "$video")" 2>/dev/null || true
  fi
  report_append "$rec"
  say "Bundle saved at $b"
  [[ ${BF_POPUP:-0} == 1 ]] && read -rp "Press Enter to close…" _
  return 0
}
