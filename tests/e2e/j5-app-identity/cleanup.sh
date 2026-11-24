#!/usr/bin/env bash
set -euo pipefail
. ../lib/gitea.sh; . ../lib/app.sh
unship team-a hello dev
if gitea GET "/repos/team-a/deploy/contents/xrs/dev/hello-identity.yaml?ref=main" | tail -1 | grep -q 200; then
  n="$(pr_delete_file team-a/deploy "j5-cleanup-$(date +%s)" xrs/dev/hello-identity.yaml "Delete hello's identity")"
  pr_merge team-a/deploy "$n" >/dev/null
fi
kubectl delete serviceaccount -A -l e2e=j5 --ignore-not-found >/dev/null
# A paused XR left behind by a failed run: unpause it so Crossplane can finish deleting it.
if kubectl -n tenant-team-a-dev get postgresqlinstance j5-owner >/dev/null 2>&1; then
  kubectl -n tenant-team-a-dev annotate postgresqlinstance j5-owner crossplane.io/paused- >/dev/null 2>&1 || true
  kubectl -n tenant-team-a-dev delete postgresqlinstance j5-owner --wait=true --timeout=180s >/dev/null 2>&1 || true
fi
echo "j5 cleaned up"
