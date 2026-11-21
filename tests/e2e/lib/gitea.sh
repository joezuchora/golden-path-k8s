#!/usr/bin/env bash
# Helpers for e2e suites that act on the in-cluster Gitea (D-043) as a developer would: branch, commit, PR, merge.
# Source it; it opens a port-forward and closes it on exit. Uses the admin credential generated at bootstrap.
set -euo pipefail
jq() { command jq "$@" | tr -d '\r'; }   # the Windows jq build ends lines with CRLF; strip it so values are safe in URLs
GITEA_PORT="${GITEA_PORT:-13001}"
kubectl -n gitea port-forward svc/gitea-http "$GITEA_PORT:3000" >/dev/null 2>&1 &
_gitea_pf=$!
trap 'kill $_gitea_pf 2>/dev/null || true; [ -n "${_argo_pf:-}" ] && kill $_argo_pf 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do curl -sf "http://127.0.0.1:$GITEA_PORT/api/healthz" >/dev/null 2>&1 && break; sleep 1; done
_gpw="$(kubectl -n gitea get secret gitea-admin -o jsonpath='{.data.password}' | base64 -d)"

gitea() { # method path [json] → body, then a last line with the HTTP code
  curl -sS -u "gitea_admin:$_gpw" -X "$1" -H 'Content-Type: application/json' ${3:+-d "$3"} \
    -w '\n%{http_code}' "http://127.0.0.1:$GITEA_PORT/api/v1$2"
}
b64() { base64 | tr -d '\n'; }

# pr_put_file <owner/repo> <branch> <path> <content-file> <title> → prints the PR number
pr_put_file() {
  local repo=$1 br=$2 path=$3 file=$4 title=$5 sha body method
  sha="$(gitea GET "/repos/$repo/contents/$path?ref=main" | sed '$d' | jq -r '.sha // empty' 2>/dev/null || true)"
  body="$(jq -n --arg c "$(b64 <"$file")" --arg b "$br" --arg m "$title" --arg s "$sha" \
    '{content:$c, branch:"main", new_branch:$b, message:$m} + (if $s != "" then {sha:$s} else {} end)')"
  method=POST; [ -n "$sha" ] && method=PUT
  gitea "$method" "/repos/$repo/contents/$path" "$body" | tail -1 | grep -qE '^20[01]$' \
    || { echo "FAIL: commit $path to $repo@$br" >&2; return 1; }
  gitea POST "/repos/$repo/pulls" "$(jq -n --arg h "$br" --arg t "$title" '{head:$h, base:"main", title:$t}')" | sed '$d' | jq -r .number
}

# pr_delete_file <owner/repo> <branch> <path> <title> → prints the PR number
pr_delete_file() {
  local repo=$1 br=$2 path=$3 title=$4 sha
  sha="$(gitea GET "/repos/$repo/contents/$path?ref=main" | sed '$d' | jq -r .sha)"
  gitea DELETE "/repos/$repo/contents/$path" \
    "$(jq -n --arg b "$br" --arg m "$title" --arg s "$sha" '{branch:"main", new_branch:$b, message:$m, sha:$s}')" >/dev/null
  gitea POST "/repos/$repo/pulls" "$(jq -n --arg h "$br" --arg t "$title" '{head:$h, base:"main", title:$t}')" | sed '$d' | jq -r .number
}

# pr_merge <owner/repo> <number> → prints the merge commit SHA. Gitea checks a new PR's mergeability asynchronously and
# refuses a merge (HTTP 405) until that check finishes, so a PR opened right after another one on the same repo can be
# refused for a few seconds. Retry for up to a minute, then fail with Gitea's own answer.
pr_merge() {
  local out code
  for _ in $(seq 1 12); do
    out="$(gitea POST "/repos/$1/pulls/$2/merge" '{"Do":"merge","delete_branch_after_merge":true}')"; code="$(echo "$out" | tail -1)"
    case "$code" in 20?) gitea GET "/repos/$1/pulls/$2" | sed '$d' | jq -r .merge_commit_sha; return 0 ;; esac
    sleep 5
  done
  echo "FAIL: merge $1#$2 → HTTP $code: $(echo "$out" | sed '$d' | head -c 300)" >&2; return 1
}

# commit_statuses <owner/repo> <sha> → JSON array of the commit's statuses, newest first
commit_statuses() { gitea GET "/repos/$1/commits/$2/statuses?sort=newest" | sed '$d'; }

# Ask Argo CD to regenerate an ApplicationSet now instead of waiting for its poll.
appset_refresh() { kubectl -n argocd annotate "applicationset/$1" argocd.argoproj.io/application-set-refresh=true --overwrite >/dev/null 2>&1 || true; }
