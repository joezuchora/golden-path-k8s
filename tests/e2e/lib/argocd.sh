#!/usr/bin/env bash
# Helpers for e2e suites that call the Argo CD API as a team (kind identity substitute, D-050).
# Source it; it opens a port-forward to argocd-server and closes it on exit.
set -euo pipefail
jq() { command jq "$@" | tr -d '\r'; }   # the Windows jq build ends lines with CRLF; strip it so values are safe in URLs
ARGO_PORT="${ARGO_PORT:-18080}"
kubectl -n argocd port-forward svc/argocd-server "$ARGO_PORT:80" >/dev/null 2>&1 &
_argo_pf=$!
trap 'kill $_argo_pf 2>/dev/null || true; [ -n "${_gitea_pf:-}" ] && kill $_gitea_pf 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do curl -sf "http://127.0.0.1:$ARGO_PORT/healthz" >/dev/null 2>&1 && break; sleep 1; done
argo() { # token method path [json] → body; prints HTTP code to fd 3 if open
  local tok=$1 m=$2 p=$3 d=${4:-}
  curl -sS -X "$m" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' ${d:+-d "$d"} \
    -w '\n%{http_code}' "http://127.0.0.1:$ARGO_PORT/api/v1$p"
}
argo_admin_token() {
  local pw; pw="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
  curl -sS -H 'Content-Type: application/json' -d "{\"username\":\"admin\",\"password\":\"$pw\"}" \
    "http://127.0.0.1:$ARGO_PORT/api/v1/session" | jq -r .token
}
argo_team_token() { # team → API token for the team's local account (minted by the platform admin)
  local adm; adm="$(argo_admin_token)"
  argo "$adm" POST "/account/$1/token" "{\"name\":\"e2e-$(date +%s)\",\"expiresIn\":3600}" | head -1 | jq -r .token
}
code_of() { tail -1; }
body_of() { sed '$d'; }
