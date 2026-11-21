#!/usr/bin/env bash
# gitea.sh: seed the in-cluster Gitea (D-043) — the platform repo snapshot, the test teams' deploy repos, the
# notification bot and its token. Sourced by bootstrap.sh; also runnable: bash infra/kind/gitea.sh seed|push-platform
# Credentials are generated at bootstrap and live only in cluster Secrets; nothing secret is written to the repo.
set -euo pipefail
jq() { command jq "$@" | tr -d '\r'; }   # the Windows jq build ends lines with CRLF; strip it so values are safe in URLs
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
CTX="${CTX:-kind-golden-path}"
# shellcheck disable=SC1091
. "$ROOT/repo-coords.env"
GITEA_LOCAL_PORT="${GITEA_LOCAL_PORT:-13000}"
TEAMS_SEEDED="${TEAMS_SEEDED:-team-a team-b}"

_pf_pid=""
gitea_open() {
  kubectl --context "$CTX" -n gitea port-forward svc/gitea-http "$GITEA_LOCAL_PORT:3000" >/dev/null 2>&1 &
  _pf_pid=$!
  for _ in $(seq 1 30); do curl -sf "http://127.0.0.1:$GITEA_LOCAL_PORT/api/healthz" >/dev/null && return 0; sleep 1; done
  echo "FAIL: Gitea port-forward didn't come up"; return 1
}
gitea_close() { [ -n "$_pf_pid" ] && kill "$_pf_pid" 2>/dev/null || true; _pf_pid=""; }

admin_pw() { kubectl --context "$CTX" -n gitea get secret gitea-admin -o jsonpath='{.data.password}' | base64 -d; }
api() { # method path [json]
  local m=$1 p=$2; shift 2
  curl -sS -u "gitea_admin:$(admin_pw)" -X "$m" -H 'Content-Type: application/json' \
    "http://127.0.0.1:$GITEA_LOCAL_PORT/api/v1$p" ${1:+-d "$1"} -o /tmp/gitea.$$ -w '%{http_code}'
}
ensure() { # what method path json  → accepts 2xx, or 409/422 (already exists)
  local code; code="$(api "$2" "$3" "$4")"
  case "$code" in 2??) echo "  created $1";; 409|422) echo "  exists  $1";; *) echo "FAIL: $1 → HTTP $code: $(cat /tmp/gitea.$$)"; return 1;; esac
}

push_platform() {
  # Snapshot of the files Git tracks (the index), with their working-tree contents, so kind tests what's on disk without
  # publishing anything you haven't added: the in-cluster repo is readable by anything that reaches Gitea. A new file is
  # published once you `git add` it. A tracked file deleted from disk is left out (the deletion is published).
  local tmp; tmp="$(mktemp -d)"
  (cd "$ROOT" && git ls-files -c -z | while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done \
     | tar --null -T - -cf -) | (cd "$tmp" && tar -xf -)
  local untracked; untracked="$(cd "$ROOT" && git ls-files -o --exclude-standard | wc -l | tr -d ' ')"
  [ "$untracked" = 0 ] || echo "  note    $untracked untracked file(s) not published; git add them to include them"

  (cd "$tmp" && git init -q -b main && git -c user.name=bootstrap -c user.email=bootstrap@kind.local add -A \
     && git -c user.name=bootstrap -c user.email=bootstrap@kind.local commit -qm "platform snapshot $(cd "$ROOT" && git rev-parse --short HEAD)$(cd "$ROOT" && git diff --quiet HEAD || echo '+dirty')" \
     && git push -qf "http://gitea_admin:$(admin_pw)@127.0.0.1:$GITEA_LOCAL_PORT/$REPO_OWNER/$REPO_NAME.git" main)
  rm -rf "$tmp"; echo "  pushed  $REPO_OWNER/$REPO_NAME (working-tree snapshot)"
}

ARGO_WEBHOOK=http://argocd-server.argocd.svc/api/webhook
ensure_hook() { # owner/repo → exactly one push hook to Argo CD (Gitea inserts a new row per POST, so look first)
  local code; code="$(api GET "/repos/$1/hooks")"
  [ "$code" = 200 ] || { echo "FAIL: list hooks $1 → HTTP $code"; return 1; }
  local ids; ids="$(jq -r --arg u "$ARGO_WEBHOOK" '[.[] | select(.config.url == $u) | .id] | sort | .[]' /tmp/gitea.$$)"
  if [ -n "$ids" ]; then
    local extra; for extra in $(echo "$ids" | tail -n +2); do api DELETE "/repos/$1/hooks/$extra" >/dev/null; done
    echo "  exists  webhook $1 → Argo CD$( [ "$(echo "$ids" | wc -l)" -gt 1 ] && echo " (removed $(( $(echo "$ids" | wc -l) - 1 )) duplicate(s))")"
    return 0
  fi
  ensure "webhook $1 → Argo CD" POST "/repos/$1/hooks" "{\"type\":\"gitea\",\"active\":true,\"events\":[\"push\"],\"config\":{\"url\":\"$ARGO_WEBHOOK\",\"content_type\":\"json\"}}"
}

seed_layout() { # team -> the deploy repo layout (D-061): xrs/<env>/README.md for every env in the team file
  local t=$1 env f body
  f="$ROOT/platform/tenancy/teams/$t.yaml"; [ -f "$f" ] || return 0
  for env in $(yq -r '.envs[]' "$f"); do
    body="$(printf 'XRs for %s, env %s. Only platform.example.org XRs belong here (tenant-namespace-xrs-only).\n' "$t" "$env" | base64 | tr -d '\n')"
    ensure "$t/deploy xrs/$env/README.md" POST "/repos/$t/deploy/contents/xrs/$env/README.md" \
      "{\"content\":\"$body\",\"message\":\"Deploy repo layout\",\"branch\":\"main\"}"
  done
}

seed() {
  ensure "org $REPO_OWNER" POST /orgs "{\"username\":\"$REPO_OWNER\",\"visibility\":\"public\"}"
  ensure "repo $REPO_OWNER/$REPO_NAME" POST "/orgs/$REPO_OWNER/repos" "{\"name\":\"$REPO_NAME\",\"private\":false,\"default_branch\":\"main\"}"
  push_platform
  # Notification bot: writes commit statuses only (D-043).
  local botpw; botpw="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)Aa1!"
  ensure "user argocd-notify" POST /admin/users "{\"username\":\"argocd-notify\",\"email\":\"argocd-notify@kind.local\",\"password\":\"$botpw\",\"must_change_password\":false}"
  api PATCH /admin/users/argocd-notify "{\"login_name\":\"argocd-notify\",\"source_id\":0,\"password\":\"$botpw\",\"must_change_password\":false}" >/dev/null
  local t
  for t in $TEAMS_SEEDED; do
    ensure "org $t" POST /orgs "{\"username\":\"$t\",\"visibility\":\"public\"}"
    ensure "repo $t/deploy" POST "/orgs/$t/repos" "{\"name\":\"deploy\",\"private\":false,\"auto_init\":true,\"default_branch\":\"main\",\"readme\":\"Default\"}"
    seed_layout "$t"
    ensure "collaborator argocd-notify on $t/deploy" PUT "/repos/$t/deploy/collaborators/argocd-notify" '{"permission":"write"}'
    ensure_hook "$t/deploy"
  done
  ensure_hook "$REPO_OWNER/$REPO_NAME"
  if ! kubectl --context "$CTX" -n argocd get secret argocd-notifications-secret >/dev/null 2>&1; then
    local name="argocd-$(date +%s)" code
    code="$(curl -sS -u "argocd-notify:$botpw" -X POST -H 'Content-Type: application/json' -o /tmp/gitea.$$ -w '%{http_code}' \
      "http://127.0.0.1:$GITEA_LOCAL_PORT/api/v1/users/argocd-notify/tokens" -d "{\"name\":\"$name\",\"scopes\":[\"write:repository\"]}")"
    [ "$code" = 201 ] || { echo "FAIL: bot token → HTTP $code: $(cat /tmp/gitea.$$)"; return 1; }
    kubectl --context "$CTX" -n argocd create secret generic argocd-notifications-secret \
      --from-literal=git-token="$(jq -r .sha1 /tmp/gitea.$$)" >/dev/null
    echo "  created argocd-notifications-secret (bot token, write:repository)"
  else echo "  exists  argocd-notifications-secret"; fi
  rm -f /tmp/gitea.$$
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  export PATH="$ROOT/.bin:$PATH"
  trap gitea_close EXIT
  gitea_open
  case "${1:-seed}" in seed) seed ;; push-platform) push_platform ;; *) echo "usage: $0 seed|push-platform"; exit 2 ;; esac
fi
