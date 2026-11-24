#!/usr/bin/env bash
# J1: ship by merging a PR. team-a merges golden-service values with the CI-signed image into its deploy repo; Argo CD
# syncs it; admission verifies signer + caller + base (D-026); the rollout becomes Healthy; the HTTPS route answers;
# the merge commit gets a success status (exit criterion 3).
set -euo pipefail
. ../lib/gitea.sh; . ../lib/app.sh; . ../lib/client.sh
fail=0
cat >/tmp/j1-values.$$ <<EOF
app: hello
env: dev
image: $HELLO_SIGNED
replicas: 2
route:
  responseHeaders: {add: {x-journey: j1}}
EOF
sha="$(ship team-a hello dev /tmp/j1-values.$$ j1-ship-hello)"; rm -f /tmp/j1-values.$$
echo "merged team-a/deploy → $sha"
wait_app team-a-hello-dev-in-cluster Synced Healthy 420 || fail=1
# Admission rewrote nothing it shouldn't, and derived the ownership labels (ADR-0007).
lbl="$(kubectl -n team-a-dev get deploy hello -o jsonpath='{.spec.template.metadata.labels.platform\.example\.org/cost-center}')"
[ "$lbl" = cc-1001 ] && echo "PASS pod template carries derived cost-center=$lbl" || { echo "FAIL derived labels missing (cost-center='$lbl')"; fail=1; }
img="$(kubectl -n team-a-dev get deploy hello -o jsonpath='{.spec.template.spec.containers[0].image}')"
[ "$img" = "$HELLO_SIGNED" ] && echo "PASS running the CI-signed digest" || { echo "FAIL image is $img"; fail=1; }
client_up
body="$(wait_http hello-team-a-dev.apps.kind.test / 200 180)" && echo "PASS https://hello-team-a-dev.apps.kind.test/ → 200: $body" || fail=1
hdr="$(in_curl hello-team-a-dev.apps.kind.test https / -D - -o /dev/null | grep -i '^x-journey:' | tr -d '\r' || true)"
[ -n "$hdr" ] && echo "PASS response header modifier: $hdr" || { echo "FAIL x-journey response header missing"; fail=1; }
redir="$(in_curl hello-team-a-dev.apps.kind.test http / | tail -1)"
[ "$redir" = 301 ] && echo "PASS http → https redirect (301)" || { echo "FAIL http returned $redir"; fail=1; }
desc="$(wait_status team-a/deploy "$sha" success team-a-hello-dev-in-cluster 300)" && echo "PASS commit status success on $sha: $desc" || fail=1
# Ship again: the next merge's sync must not reopen this commit's status (D-108). Argo CD's status.sync still names this
# commit when the next sync starts, so a status keyed on it turned a shipped commit's status back to pending for good.
printf 'app: hello\nenv: dev\nimage: %s\nreplicas: 2\nroute:\n  responseHeaders: {add: {x-journey: j1-again}}\n' "$HELLO_SIGNED" >/tmp/j1b-values.$$
sha2="$(ship team-a hello dev /tmp/j1b-values.$$ j1-ship-hello-again)"; rm -f /tmp/j1b-values.$$
echo "merged team-a/deploy → $sha2"
desc="$(wait_status team-a/deploy "$sha2" success team-a-hello-dev-in-cluster 300)" && echo "PASS commit status success on $sha2: $desc" || fail=1
prev="$(latest_status team-a/deploy "$sha" team-a-hello-dev-in-cluster)"
[ "$prev" = success ] && echo "PASS the previous merge $sha still shows success after the next sync" \
  || { echo "FAIL the previous merge $sha shows '$prev' after the next sync (want success): $(commit_statuses team-a/deploy "$sha" | jq -c '[.[] | {context, status, description}]' | cut -c1-500)"; fail=1; }
exit $fail
