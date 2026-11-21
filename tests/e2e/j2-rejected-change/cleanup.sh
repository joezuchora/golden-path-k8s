#!/usr/bin/env bash
set -euo pipefail
. ../lib/gitea.sh; . ../lib/app.sh
unship team-a hello dev
if gitea GET "/repos/team-a/deploy/contents/xrs/dev/sideloaded.yaml?ref=main" | tail -1 | grep -q 200; then
  n="$(pr_delete_file team-a/deploy "j2-cleanup-$(date +%s)" xrs/dev/sideloaded.yaml "Remove the helper deployment")"
  pr_merge team-a/deploy "$n" >/dev/null
fi
kubectl -n argocd annotate application team-a-xrs-dev argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
echo "j2 cleaned up"
