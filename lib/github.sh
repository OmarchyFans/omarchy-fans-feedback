#!/bin/bash
# GitHub transport. The end user submits with their OWN GitHub login: `gh` when
# it is authenticated, otherwise a prefilled new-issue URL in the browser.
# There is no relay and no token of the author's on the end user's machine.

gh_ready() { have gh && gh auth status >/dev/null 2>&1; }

# Create an issue. Prints the issue URL on success.
gh_issue_create() { # gh_issue_create <owner/repo> <title> <body-file> <label>
  gh issue create -R "$1" --title "$2" --body-file "$3" --label "$4" 2>/dev/null
}

# Prefilled new-issue URL (body trimmed: browsers cap URLs around 8 KB).
issue_new_url() { # issue_new_url <owner/repo> <title> <body-file> <label>
  local body; body=$(head -c 6000 "$3")
  (( $(wc -c <"$3") > 6000 )) && body+=$'\n\n_(trimmed; the full bundle is on the reporter\x27s machine)_'
  printf 'https://github.com/%s/issues/new?title=%s&body=%s&labels=%s' "$1" "$(urlencode "$2")" "$(urlencode "$body")" "$(urlencode "$4")"
}

# Issues with our label, as compact JSON [{number,title,state,labels:[..],updated_at,html_url,body}].
gh_issues_fetch() { # gh_issues_fetch <owner/repo> [since-iso]
  local repo=$1 since=${2:-} q="labels=$BF_LABEL&state=all&per_page=100"
  [[ -n $since ]] && q+="&since=$since"
  if gh_ready; then
    gh api "repos/$repo/issues?$q" --paginate 2>/dev/null
  elif have curl; then
    curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$repo/issues?$q" 2>/dev/null
  else
    printf '[]'
  fi | jq -c '[.[]? | select(.pull_request == null) | {number, title, state, labels: [.labels[].name], updated_at, html_url, body}]'
}

# Search issues whose body carries our reporter marker (browser-submitted
# reports have no issue number until we find them this way).
gh_issues_search_marker() { # gh_issues_search_marker <owner/repo> <marker>
  local q; q=$(urlencode "repo:$1 \"$2\" in:body")
  if gh_ready; then gh api "search/issues?q=$q" 2>/dev/null
  elif have curl; then curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/search/issues?q=$q" 2>/dev/null
  else printf '{"items":[]}'; fi | jq -c '[.items[]? | {number, html_url, state, labels: [.labels[].name]}]'
}

gh_issue_comment() { # gh_issue_comment <owner/repo> <number> <body-file>
  gh issue comment "$2" -R "$1" --body-file "$3" >/dev/null 2>&1
}
issue_comment_url() { printf 'https://github.com/%s/issues/%s#new_comment_field' "$1" "$2"; }
