#!/usr/bin/env bash
# J3: an unhealthy rollout shows the next action (exit criterion 5). team-a merges a configuration mistake (the app
# listens on 9090, the probes check 8080). Argo CD reports Degraded, the commit status says so and names the diagnosis
# command, and idp-diagnose.sh, run as a team-a developer, names the failing step and the next action. The developer
# identity can't read cluster-scoped objects (O1), so the diagnosis provably needs none.
set -euo pipefail
. ../lib/gitea.sh; . ../lib/app.sh; . ../lib/argocd.sh
fail=0
printf 'app: hello\nenv: dev\nimage: %s\nreplicas: 1\nprogressDeadlineSeconds: 60\nextraEnv: {PORT: "9090"}\n' "$HELLO_SIGNED" >/tmp/j3.$$
sha="$(ship team-a hello dev /tmp/j3.$$ j3-wrong-port)"; rm -f /tmp/j3.$$
echo "merged team-a/deploy → $sha"
wait_app team-a-hello-dev Synced Degraded 420 || fail=1
cmd=""
if d="$(wait_status team-a/deploy "$sha" failure team-a-hello-dev 300)"; then
  cmd="$(echo "$d" | grep -oE 'scripts/idp-diagnose\.sh [^ ]+ [^ ]+ --team [^ ."]+' | head -1 || true)"
  [ -n "$cmd" ] && echo "PASS commit status names the exact next command: $cmd" || { echo "FAIL status lacks a runnable diagnosis command: $d"; fail=1; }
else fail=1; fi
[ "$cmd" = "scripts/idp-diagnose.sh hello dev --team team-a" ] || { echo "FAIL published command is '$cmd'"; fail=1; }
[ "$(kubectl auth can-i list namespaces --as dev-a --as-group team-a)" = no ] && echo "PASS the developer identity has no cluster-scoped reads"
export ARGOCD_TOKEN; ARGOCD_TOKEN="$(argo_team_token team-a)"; export ARGOCD_URL="http://127.0.0.1:$ARGO_PORT"
# Run exactly the published command, as the developer.
out="$(cd ../../.. && bash $cmd --as dev-a || true)"
echo "$out" | sed 's/^/    /'
for want in "FAILED STEP: Rollout" "NEXT ACTION: Revert the PR, or fix and re-merge" "probe failed: Get" "connection refused"; do
  case "$out" in *"$want"*) echo "PASS diagnosis shows '$want'";; *) echo "FAIL diagnosis lacks '$want'"; fail=1;; esac
done
case "$out" in *Forbidden*|*forbidden*) echo "FAIL the diagnosis hit a forbidden read"; fail=1;; esac
exit $fail
