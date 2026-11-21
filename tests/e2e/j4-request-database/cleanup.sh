#!/usr/bin/env bash
set -euo pipefail
. ../lib/gitea.sh; . ../lib/app.sh
unship team-a hello dev
if gitea GET "/repos/team-a/deploy/contents/xrs/dev/orders-db.yaml?ref=main" | tail -1 | grep -q 200; then
  n="$(pr_delete_file team-a/deploy "j4-cleanup-$(date +%s)" xrs/dev/orders-db.yaml "Delete orders-db")"
  pr_merge team-a/deploy "$n" >/dev/null
fi
echo "j4 cleaned up"
