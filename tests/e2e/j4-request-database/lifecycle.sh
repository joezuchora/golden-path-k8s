#!/usr/bin/env bash
# J4: request a database; "Ready" means the app can use it (exit criterion 6, ADR-0002 steps 1-5, D-024).
#   1. XR by PR -> Ready          2. ExternalSecret synced into the app namespace (and not readable by another team)
#   3. the app's readiness probe runs a real query   4. rotate -> Reloader restarts -> reconnects
#   5. delete the XR -> database, vault secret and delivered secret gone, no finalizers left
set -euo pipefail
. ../lib/gitea.sh; . ../lib/app.sh; . ../lib/client.sh
fail=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
waitfor() { # description timeout-s condition
  local i; for i in $(seq 1 $(($2 / 5))); do eval "$3" && { echo "PASS $1"; return 0; }; sleep 5; done
  echo "FAIL $1 (after $2 s)"; fail=1; return 1
}
T=tenant-team-a-dev; A=team-a-dev; V=vault-team-a-dev
# gone <kubectl get args>: true only on an explicit NotFound; an API or authorization error is not a deletion.
gone() { local out; out="$(kubectl get "$@" 2>&1)" && return 1; [[ "$out" == *NotFound* || "$out" == *"not found"* ]]; }
podset() { kubectl -n $A get pods -l platform.example.org/app=hello -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}'; }

echo "== 1. request the database by PR"
printf 'apiVersion: platform.example.org/v1\nkind: PostgreSQLInstance\nmetadata: {name: orders-db}\nspec: {storageGB: 1}\n' >/tmp/j4xr.$$
n="$(pr_put_file team-a/deploy j4-orders-db xrs/dev/orders-db.yaml /tmp/j4xr.$$ "Request orders-db")"; rm -f /tmp/j4xr.$$
pr_merge team-a/deploy "$n" >/dev/null; appset_refresh xrs-team-a
kubectl -n argocd annotate application team-a-xrs-dev argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
waitfor "XR $T/orders-db Ready" 420 "[ \"\$(kubectl -n $T get postgresqlinstance orders-db -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null)\" = True ]"
check "composed CloudNativePG cluster carries the derived tags" "[ \"\$(kubectl -n $T get cluster.postgresql.cnpg.io orders-db -o jsonpath='{.metadata.labels.platform\.example\.org/cost-center}')\" = cc-1001 ]"
waitfor "connection details pushed to the team's vault" 120 "kubectl -n $V get secret orders-db >/dev/null 2>&1"

echo "== 2-3. the app declares the dependency; its readiness probe queries the database"
printf 'app: hello\nenv: dev\nimage: %s\nreplicas: 1\ndependencies: {postgres: [orders-db]}\n' "$HELLO_SIGNED" >/tmp/j4app.$$
ship team-a hello dev /tmp/j4app.$$ j4-hello-db >/dev/null; rm -f /tmp/j4app.$$
waitfor "ExternalSecret hello-orders-db-db synced into $A" 300 "[ \"\$(kubectl -n $A get externalsecret hello-orders-db-db -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null)\" = True ]"
wait_app team-a-hello-dev Synced Healthy 420 || fail=1
client_up
out="$(wait_http hello-team-a-dev.apps.kind.test /readyz 200 180 || true)"
check "readiness is a real query through the brokered credential: /readyz says '$out'" "[[ \"$out\" == *'database query ok'* ]]"
check "cross-tenant: team-b's secret reader can't read team-a's vault" "[ \"\$(kubectl auth can-i get secrets -n $V --as system:serviceaccount:team-b-dev:eso-vault-reader)\" = no ]"
check "developers can't read the vault or the delivered secret" "[ \"\$(kubectl auth can-i get secrets -n $V --as dev-a --as-group team-a)\" = no ] && [ \"\$(kubectl auth can-i get secrets -n $A --as dev-a --as-group team-a)\" = no ]"

echo "== 4. rotate the credential; the app restarts and reconnects"
before="$(kubectl -n $A get deploy hello -o jsonpath='{.metadata.generation}')"   # Reloader changes the pod template's env, so the generation moves
oldpods="$(podset)"
newpw="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
kubectl -n $T patch secret orders-db-app --type merge -p "{\"stringData\":{\"password\":\"$newpw\"}}" >/dev/null
waitfor "the rotated password reached the app namespace" 180 "[ \"\$(kubectl -n $A get secret hello-orders-db-db -o jsonpath='{.data.password}' | base64 -d)\" = '$newpw' ]"
waitfor "Reloader restarted the Deployment (generation moved past $before)" 180 "[ \"\$(kubectl -n $A get deploy hello -o jsonpath='{.metadata.generation}')\" -gt $before ]"
# The rollout is complete only when the controller has seen the new spec and the only pods left are new ones.
rollout_done() { # new spec observed, 1 updated/ready/total replica, and none of the pods from before the rotation left
  local g o u r t p
  read -r g o u r t <<<"$(kubectl -n $A get deploy hello -o jsonpath='{.metadata.generation} {.status.observedGeneration} {.status.updatedReplicas} {.status.readyReplicas} {.status.replicas}')"
  [ "${o:-0}" -ge "${g:-1}" ] && [ "$u/$r/$t" = 1/1/1 ] || return 1
  for p in $oldpods; do [[ " $(podset) " == *" $p "* ]] && return 1; done; return 0
}
waitfor "the restarted rollout is complete (new spec observed, 1/1 ready, no pod from before the rotation)" 300 rollout_done
newpods="$(podset)"; echo "INFO pods before rotation: $oldpods; after: $newpods"
out="$(wait_http hello-team-a-dev.apps.kind.test /readyz 200 120 || true)"
check "after rotation the app queries with the new credential: /readyz says '$out'" "[[ \"$out\" == *'database query ok'* ]]"

echo "== 5. delete the XR; nothing is left behind"
n="$(pr_delete_file team-a/deploy "j4-delete-$(date +%s)" xrs/dev/orders-db.yaml "Delete orders-db")"; pr_merge team-a/deploy "$n" >/dev/null
kubectl -n argocd annotate application team-a-xrs-dev argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
waitfor "XR deleted (no finalizers left)" 300 "gone -n $T postgresqlinstance orders-db"
waitfor "CloudNativePG cluster and its volumes gone" 300 "gone -n $T cluster.postgresql.cnpg.io orders-db && pvcs=\$(kubectl -n $T get pvc -l cnpg.io/cluster=orders-db -o name) && [ -z \"\$pvcs\" ]"
waitfor "vault secret deleted (PushSecret deletionPolicy: Delete)" 180 "gone -n $V secret orders-db"
waitfor "delivered secret removed from the app namespace" 180 "gone -n $A secret hello-orders-db-db"
exit $fail
