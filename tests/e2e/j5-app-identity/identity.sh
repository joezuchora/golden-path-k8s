#!/usr/bin/env bash
# J5: get an app identity (ADR-0013 slice 2, kind fitness check). kind has no Microsoft Entra ID, so nothing exchanges the
# token (ADR-0008's stated deviation). Instead the suite checks the token the kubelet actually mounted against the
# federation record the AppIdentity composes: the issuer, subject and audience the azure composition gives Entra.
#   1. AppIdentity by PR -> Ready; federation record composed; IDs pushed to the team's vault
#   2. the app opts in (identity.enabled) -> the identity Secret reaches its namespace; the AZURE_* variables use it
#   3. the mounted token matches the federation record (issuer, subject, audience) and is bound to the app's pod
#   4. deny: tokens for another ServiceAccount in the namespace, for another team's same-named app, and for another
#      audience don't match; a database's owning app can't be changed or removed
#   5. delete the AppIdentity by PR -> everything it created is gone, including the delivered Secret
set -euo pipefail
. ../lib/gitea.sh; . ../lib/app.sh
fail=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
waitfor() { # description timeout-s condition
  local i; for i in $(seq 1 $(($2 / 5))); do eval "$3" && { echo "PASS $1"; return 0; }; sleep 5; done
  echo "FAIL $1 (after $2 s)"; fail=1; return 1
}
T=tenant-team-a-dev; A=team-a-dev; V=vault-team-a-dev
# gone <kubectl get args>: true only on an explicit NotFound; an API or authorization error is not a deletion.
gone() { local out; out="$(kubectl get "$@" 2>&1)" && return 1; [[ "$out" == *NotFound* || "$out" == *"not found"* ]]; }
# claims <jwt>: the token's payload as JSON. Only claims are ever printed, never a token.
claims() {
  local p; p="$(cut -d. -f2 <<<"$1" | tr '_-' '/+')"
  while [ $(( ${#p} % 4 )) -ne 0 ]; do p="$p="; done
  base64 -d <<<"$p"
}
# matches <claims-json>: true when a federated credential built from the record would accept the token: its issuer is
# one of the record's, and its subject and audience are the record's (Entra matches all three exactly, F62).
matches() {
  local iss sub; iss="$(jq -r .iss <<<"$1")"; sub="$(jq -r .sub <<<"$1")"
  grep -qxF -- "$iss" <<<"$ISSUERS" && [ "$sub" = "$SUBJECT" ] && jq -e --arg a "$AUDIENCE" '.aud | index($a) != null' <<<"$1" >/dev/null
}
# tokenclaims <namespace> <serviceaccount> [audience]: claims of a fresh TokenRequest token
tokenclaims() { claims "$(kubectl -n "$1" create token "$2" --audience "${3:-api://AzureADTokenExchange}" --duration 10m)"; }

echo "== 1. declare the identity by PR"
printf 'apiVersion: platform.example.org/v1\nkind: AppIdentity\nmetadata: {name: hello}\nspec: {}\n' >/tmp/j5xr.$$
n="$(pr_put_file team-a/deploy j5-hello-identity xrs/dev/hello-identity.yaml /tmp/j5xr.$$ "Declare hello's identity")"; rm -f /tmp/j5xr.$$
pr_merge team-a/deploy "$n" >/dev/null; appset_refresh xrs-team-a
kubectl -n argocd annotate application team-a-xrs-dev argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
waitfor "XR $T/hello (AppIdentity) Ready" 300 "[ \"\$(kubectl -n $T get appidentity hello -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null)\" = True ]"
SUBJECT="$(kubectl -n $T get configmap hello-federation -o jsonpath='{.data.subject}')"
ISSUERS="$(kubectl -n $T get configmap hello-federation -o jsonpath='{.data.issuers}')"
AUDIENCE="$(kubectl -n $T get configmap hello-federation -o jsonpath='{.data.audience}')"
echo "INFO federation record: subject=$SUBJECT issuers=$(tr '\n' ' ' <<<"$ISSUERS")audience=$AUDIENCE"
check "the subject is derived from the tenant namespace, not the request" "[ \"\$SUBJECT\" = system:serviceaccount:$A:hello ]"
check "the XR's status names the identity Secret and the subject" "[ \"\$(kubectl -n $T get appidentity hello -o jsonpath='{.status.identitySecret} {.status.subject}')\" = \"appidentity-hello \$SUBJECT\" ]"
waitfor "client and tenant IDs pushed to the team's vault under appidentity-hello" 120 "[ -n \"\$(kubectl -n $V get secret appidentity-hello -o jsonpath='{.data.clientId}' 2>/dev/null)\" ]"

echo "== 2. the app opts in; the identity reaches its namespace"
printf 'app: hello\nenv: dev\nimage: %s\nreplicas: 1\nidentity: {enabled: true}\n' "$HELLO_SIGNED" >/tmp/j5app.$$
ship team-a hello dev /tmp/j5app.$$ j5-hello-identity-app >/dev/null; rm -f /tmp/j5app.$$
waitfor "ExternalSecret hello-identity synced into $A" 300 "[ \"\$(kubectl -n $A get externalsecret hello-identity -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null)\" = True ]"
check "the delivered Secret carries the IDs (placeholders on kind)" "[ \"\$(kubectl -n $A get secret hello-identity -o jsonpath='{.data.clientId}' | base64 -d)/\$(kubectl -n $A get secret hello-identity -o jsonpath='{.data.tenantId}' | base64 -d)\" = local/local ]"
wait_app team-a-hello-dev-in-cluster Synced Healthy 420 || fail=1
POD="$(kubectl -n $A get pods -l platform.example.org/app=hello,platform.example.org/track=stable --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
check "the pod runs as the app's ServiceAccount" "[ \"\$(kubectl -n $A get pod $POD -o jsonpath='{.spec.serviceAccountName}')\" = hello ]"
check "AZURE_CLIENT_ID comes from the identity Secret" "[ \"\$(kubectl -n $A get pod $POD -o jsonpath='{.spec.containers[0].env[?(@.name==\"AZURE_CLIENT_ID\")].valueFrom.secretKeyRef.name}')\" = hello-identity ]"

echo "== 3. the token the kubelet mounted matches the federation record"
# Read from the pod's node (a kind node is a container), because the app image has no shell.
NODE="$(kubectl -n $A get pod "$POD" -o jsonpath='{.spec.nodeName}')"; PODUID="$(kubectl -n $A get pod "$POD" -o jsonpath='{.metadata.uid}')"
C="$(claims "$(MSYS_NO_PATHCONV=1 docker exec "$NODE" cat "/var/lib/kubelet/pods/$PODUID/volumes/kubernetes.io~projected/azure-identity-token/azure-identity-token")")"
echo "INFO mounted token: iss=$(jq -r .iss <<<"$C") sub=$(jq -r .sub <<<"$C") aud=$(jq -c .aud <<<"$C") pod=$(jq -r '."kubernetes.io".pod.name' <<<"$C")"
check "the mounted token matches the federation record (issuer, subject, audience)" 'matches "$C"'
check "the mounted token is bound to the app's pod" '[ "$(jq -r ".\"kubernetes.io\".pod.name" <<<"$C")" = "$POD" ]'

echo "== 4. what must not match"
for sa in "$A impostor" "team-b-dev hello"; do
  read -r ns name <<<"$sa"
  kubectl -n "$ns" create serviceaccount "$name" --dry-run=client -o yaml | kubectl label --local -f - e2e=j5 -o yaml | kubectl apply -f - >/dev/null
done
# denied <claims-json> <subject> <audience>: the token was issued for that subject and audience, and the record doesn't
# accept it. Checking the issued claims first keeps a failed or empty TokenRequest from passing as a denial.
denied() {
  [ "$(jq -r .sub <<<"$1" 2>/dev/null)" = "$2" ] && jq -e --arg a "$3" '.aud | index($a) != null' <<<"$1" >/dev/null 2>&1 && ! matches "$1"
}
check "another ServiceAccount in $A doesn't match" 'denied "$(tokenclaims $A impostor)" system:serviceaccount:$A:impostor api://AzureADTokenExchange'
check "team-b's same-named app (team-b-dev/hello) doesn't match" 'denied "$(tokenclaims team-b-dev hello)" system:serviceaccount:team-b-dev:hello api://AzureADTokenExchange'
check "the app's own ServiceAccount, for the Kubernetes API audience, doesn't match" 'denied "$(tokenclaims $A hello https://kubernetes.default.svc.cluster.local)" system:serviceaccount:$A:hello https://kubernetes.default.svc.cluster.local'
check "control: a TokenRequest for the app's own ServiceAccount and the record's audience matches" 'matches "$(tokenclaims $A hello)"'
# A database's owning app is immutable once set (D-102). The XR is paused, so nothing is composed for it.
kubectl apply -f - >/dev/null <<YAML
apiVersion: platform.example.org/v1
kind: PostgreSQLInstance
metadata: {name: j5-owner, namespace: $T, labels: {e2e: j5}, annotations: {crossplane.io/paused: "true"}}
spec: {app: hello}
YAML
out="$(kubectl -n $T patch postgresqlinstance j5-owner --type merge -p '{"spec":{"app":"other"}}' 2>&1 || true)"
check "changing a database's owning app is rejected: ${out:0:160}" '[[ "$out" == *"spec.app is immutable"* ]]'
out="$(kubectl -n $T patch postgresqlinstance j5-owner --type json -p '[{"op":"remove","path":"/spec/app"}]' 2>&1 || true)"
check "removing a database's owning app is rejected" '[[ "$out" == *"spec.app is immutable"* ]]'
kubectl -n $T delete postgresqlinstance j5-owner --wait=true --timeout=60s >/dev/null 2>&1 || true

echo "== 5. delete the identity by PR; nothing is left behind"
n="$(pr_delete_file team-a/deploy "j5-delete-$(date +%s)" xrs/dev/hello-identity.yaml "Delete hello's identity")"; pr_merge team-a/deploy "$n" >/dev/null
kubectl -n argocd annotate application team-a-xrs-dev argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
waitfor "XR deleted (no finalizers left)" 300 "gone -n $T appidentity hello"
waitfor "federation record, identity Secret and PushSecret gone" 120 "gone -n $T configmap hello-federation && gone -n $T secret hello-appidentity && gone -n $T pushsecret appidentity-hello"
waitfor "vault entry deleted (PushSecret deletionPolicy: Delete)" 120 "gone -n $V secret appidentity-hello"
waitfor "delivered Secret removed from the app namespace" 180 "gone -n $A secret hello-identity"
exit $fail
