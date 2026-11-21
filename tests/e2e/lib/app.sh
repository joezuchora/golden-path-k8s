#!/usr/bin/env bash
# Ship and remove apps the way a team does: a PR to its deploy repo (D-061). Requires lib/gitea.sh.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/images.env"
# ship <team> <app> <env> <values-file> <branch> → prints the merge commit SHA
ship() {
  local n; n="$(pr_put_file "$1/deploy" "$5" "apps/$2/$3.yaml" "$4" "Ship $2 to $3")"
  pr_merge "$1/deploy" "$n"
  appset_refresh "apps-$1"
}
# unship <team> <app> <env>: remove the values file by PR; the platform team deletes the Application (D-061).
unship() {
  local n
  if gitea GET "/repos/$1/deploy/contents/apps/$2/$3.yaml?ref=main" | tail -1 | grep -q 200; then
    n="$(pr_delete_file "$1/deploy" "remove-$2-$3-$(date +%s)" "apps/$2/$3.yaml" "Remove $2 from $3")"
    pr_merge "$1/deploy" "$n" >/dev/null
  fi
  # One Application per workload cluster in the env's group (<team>-<app>-<env>-<cluster>, D-079): select by label.
  kubectl -n argocd delete application -l "platform.example.org/team=$1,platform.example.org/app=$2,platform.example.org/env=$3"     --ignore-not-found --wait=true --timeout=180s >/dev/null
}
# wait_app <name> <sync> <health> [timeout s]
wait_app() {
  local a=$1 want="$2/$3" t=${4:-300} got
  for _ in $(seq 1 $((t / 5))); do
    got="$(kubectl -n argocd get application "$a" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)"
    [ "$got" = "$want" ] && { echo "PASS Argo CD $a: $got"; return 0; }
    sleep 5
  done
  echo "FAIL Argo CD $a: $got (want $want): $(kubectl -n argocd get application "$a" -o jsonpath='{.status.operationState.message}' 2>/dev/null | cut -c1-300)"; return 1
}
# wait_status <owner/repo> <sha> <state> <application> [timeout s] → prints that application's status description.
# One deploy-repo commit can get statuses from several applications (the team's apps and its XRs share the repo), so the
# caller names the one it expects.
wait_status() {
  local repo=$1 sha=$2 want=$3 app=$4 t=${5:-300} s
  for _ in $(seq 1 $((t / 5))); do
    s="$(commit_statuses "$repo" "$sha" | jq -r --arg w "$want" --arg c "platform/argocd/$app" '[.[] | select(.context == $c) | select(.status == $w)][0].description // empty')"
    [ -n "$s" ] && { echo "$s"; return 0; }
    sleep 5
  done
  echo "FAIL: no '$want' commit status from platform/argocd/$app on $repo@$sha. Statuses: $(commit_statuses "$repo" "$sha" | jq -c '[.[] | {context, status, description}]' | cut -c1-500)" >&2
  return 1
}
