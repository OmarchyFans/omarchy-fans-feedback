#!/bin/bash
# Enrollment state for end users: who opted in, for how long, on which channel.
# enrollments.json: { "<pluginId>": { status, enrolledAt, daysUsed, lastPing,
#                     channel, installedSha, repo } }

enroll_all() { json_file_or "$BF_ENROLL" '{}'; }
enroll_get() { enroll_all | jq -c --arg id "$1" '.[$id] // null'; }
enroll_set() { # enroll_set <pluginId> <json-object>
  json_write "$BF_ENROLL" "$(enroll_all | jq --arg id "$1" --argjson v "$2" '.[$id] = $v')"
}

reporter_id() {
  ensure_state
  if [[ ! -s $BF_STATE/reporter-id ]]; then
    { cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N; } | cut -c1-8 | sed 's/^/bf-/' >"$BF_STATE/reporter-id"
  fi
  tr -d '\n' <"$BF_STATE/reporter-id"
}

# The repo a plugin reports to: .beta-feedback.json in the plugin dir wins,
# else the GitHub origin of its clone. Prints owner/name or nothing.
plugin_repo() { # plugin_repo <pluginId>
  local dir cfg url
  dir=$(plugin_dir "$1")
  cfg="$dir/.beta-feedback.json"
  if [[ -f $cfg ]]; then
    jq -r '.repo // empty' "$cfg" 2>/dev/null && return 0
  fi
  url=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 0
  sed -nE 's#^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)([^/]+/[^/]+?)(\.git)?/?$#\2#p' <<<"$url"
}
plugin_cfg() { # plugin_cfg <pluginId> <jq-path> <default>
  local cfg; cfg="$(plugin_dir "$1")/.beta-feedback.json"
  if [[ -f $cfg ]]; then jq -r --arg d "$3" "$2 // \$d" "$cfg" 2>/dev/null; else printf '%s' "$3"; fi
}
plugin_sha()    { git -C "$(plugin_dir "$1")" rev-parse --short=12 HEAD 2>/dev/null; }
plugin_branch() { git -C "$(plugin_dir "$1")" rev-parse --abbrev-ref HEAD 2>/dev/null; }
plugin_version() { jq -r '.version // "?"' "$(plugin_dir "$1")/manifest.json" 2>/dev/null || echo "?"; }

# status: the SDK calls this on every panel open. It also advances the
# days-used clock (once per calendar day) and expires the enrollment after
# BF_BETA_DAYS days of use.
cmd_status() { # cmd_status <pluginId> [--json]
  local id=$1 e status today repo
  require_plugin_id "$id"; ensure_state
  e=$(enroll_get "$id"); today=$(today)
  if [[ $e != null ]]; then
    status=$(jq -r .status <<<"$e")
    if [[ $status == enrolled && $(jq -r '.lastPing // ""' <<<"$e") != "$today" ]]; then
      e=$(jq --arg d "$today" '.daysUsed = ((.daysUsed // 0) + 1) | .lastPing = $d' <<<"$e")
      if (( $(jq -r .daysUsed <<<"$e") > BF_BETA_DAYS )); then
        e=$(jq --arg d "$today" '.status = "expired" | .expiredAt = $d' <<<"$e")
        status=expired
        notify "Beta program ended for $id" "Thanks for testing! Re-enroll any time from the plugin's bug button."
      fi
      enroll_set "$id" "$e"
    fi
  else
    status=unknown
  fi
  repo=$(plugin_repo "$id")
  jq -cn --arg id "$id" --arg status "$status" --argjson e "$e" --arg repo "$repo" \
     --argjson days "$BF_BETA_DAYS" --arg sha "$(plugin_sha "$id")" --arg branch "$(plugin_branch "$id")" \
     --arg beta "$(plugin_cfg "$id" .betaBranch staging)" --arg stable "$(plugin_cfg "$id" .stableBranch main)" \
     --argjson reports "$(reports_for "$id")" '
    { plugin: $id, status: $status, consented: ($status == "enrolled"),
      repo: $repo, hasRepo: ($repo != ""),
      channel: (if $branch == $beta then "beta" else "stable" end),
      branch: $branch, sha: $sha, betaBranch: $beta, stableBranch: $stable,
      daysUsed: ($e.daysUsed // 0), daysLeft: ([$days - ($e.daysUsed // 0), 0] | max),
      betaDays: $days,
      updateAvailable: ($e.updateAvailable // false), updateSha: ($e.updateSha // ""),
      reports: $reports }'
}

cmd_enroll() { # cmd_enroll <pluginId>
  local id=$1 e
  require_plugin_id "$id"; ensure_state
  [[ -d $(plugin_dir "$id") ]] || fail "plugin '$id' is not installed in $BF_PLUGINS"
  e=$(jq -cn --arg d "$(today)" --arg sha "$(plugin_sha "$id")" --arg repo "$(plugin_repo "$id")" \
     '{status:"enrolled", enrolledAt:$d, daysUsed:1, lastPing:$d, channel:"stable", installedSha:$sha, repo:$repo}')
  enroll_set "$id" "$e"
  say "Enrolled $id in its beta program (expires after $BF_BETA_DAYS days of use)."
}

cmd_unenroll() { # cmd_unenroll <pluginId> [--declined]
  local id=$1 st=unenrolled
  require_plugin_id "$id"; ensure_state
  [[ ${2:-} == --declined ]] && st=declined
  enroll_set "$id" "$(jq -cn --arg d "$(today)" --arg st "$st" '{status:$st, at:$d}')"
  say "$id: $st."
}

# Reports this install filed for a plugin (from reports.jsonl), newest first.
reports_for() { # reports_for <pluginId>
  if [[ -s $BF_REPORTS ]]; then
    jq -sc --arg id "$1" '[.[] | select(.plugin == $id)] | reverse' "$BF_REPORTS"
  else printf '[]'; fi
}
report_append() { ensure_state; printf '%s\n' "$1" >>"$BF_REPORTS"; }
report_update() { # report_update <bundle-id> <jq-update>
  [[ -s $BF_REPORTS ]] || return 0
  local tmp; tmp=$(mktemp "$BF_STATE/.tmp.XXXXXX")
  jq -c --arg b "$1" "if .bundle == \$b then $2 else . end" "$BF_REPORTS" >"$tmp" && mv -f "$tmp" "$BF_REPORTS"
}

cmd_list() {
  ensure_state
  enroll_all | jq -r 'to_entries[] | "\(.key)\t\(.value.status)\t\(.value.daysUsed // 0)d used\tsince \(.value.enrolledAt // .value.at // "-")"' | column -t -s $'\t'
}
