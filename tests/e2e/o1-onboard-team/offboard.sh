#!/usr/bin/env bash
# Cleanup: remove the team by PR, then the platform team deletes its tenancy Applications (create-update policy, D-049).
set -euo pipefail
. ../lib/gitea.sh
. ../../../repo-coords.env
if gitea GET "/repos/$REPO/contents/platform/tenancy/teams/team-c.yaml?ref=main" | tail -1 | grep -q 200; then
  n="$(pr_delete_file "$REPO" offboard-team-c platform/tenancy/teams/team-c.yaml "Offboard team-c")"
  pr_merge "$REPO" "$n" >/dev/null
  echo "merged offboarding PR #$n"
fi
kubectl -n argocd delete applications -l platform.example.org/team=team-c --wait=true --timeout=180s
gitea DELETE /repos/team-c/deploy >/dev/null
gitea DELETE /orgs/team-c >/dev/null
echo "team-c removed"
