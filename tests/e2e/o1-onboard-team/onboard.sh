#!/usr/bin/env bash
# O1 step 1: a team definition PR is merged → the platform renders the team's boundary; nobody runs kubectl.
set -euo pipefail
. ../lib/gitea.sh
. ../../../repo-coords.env
# The team's own Git org and deploy repo exist before onboarding (on AKS: the team's GitHub repo).
gitea POST /orgs '{"username":"team-c","visibility":"public"}' >/dev/null
gitea POST /orgs/team-c/repos '{"name":"deploy","auto_init":true,"default_branch":"main"}' >/dev/null
gitea POST /repos/team-c/deploy/contents/xrs/dev/README.md \
  "{\"content\":\"$(printf 'XRs for team-c dev\n' | b64)\",\"message\":\"Deploy repo layout\",\"branch\":\"main\"}" >/dev/null
n="$(pr_put_file "$REPO" onboard-team-c platform/tenancy/teams/team-c.yaml ./team-c.yaml "Onboard team-c")"
echo "opened PR #$n on $REPO"
sha="$(pr_merge "$REPO" "$n")"
echo "merged PR #$n → $sha"
appset_refresh tenancy-control-plane
appset_refresh tenancy-workloads
