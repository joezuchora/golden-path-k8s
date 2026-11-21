#!/usr/bin/env bash
# Split fixture (D-023): kind hosts both capabilities, so it can't tell a swapped selector from a correct one. Register a
# second, unreachable cluster that has ONLY hosts-workloads and assert exactly which Applications target it: every
# workloads component and every team's workloads tenancy, and nothing from the control plane. The fixture is removed at
# the end; its Applications are deleted without their finalizers, because the fake cluster can't be reached.
set -euo pipefail
jq() { command jq "$@" | tr -d '\r'; }   # the Windows jq build ends lines with CRLF
ROOT="$(git rev-parse --show-toplevel)"
FAKE=split-fixture-workloads
SERVER=https://split-fixture-workloads.invalid:6443
fail=0
cleanup() {
  kubectl -n argocd delete secret "cluster-$FAKE" --ignore-not-found >/dev/null
  for a in $(kubectl -n argocd get applications -o json | jq -r --arg s "$SERVER" '.items[] | select(.spec.destination.server == $s) | .metadata.name'); do
    kubectl -n argocd patch application "$a" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
    kubectl -n argocd delete application "$a" --wait=false >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT
kubectl -n argocd get secret cluster-in-cluster -o json \
  | jq --arg n "$FAKE" --arg s "$SERVER" '.metadata = {name: ("cluster-" + $n), namespace: "argocd",
        labels: {"argocd.argoproj.io/secret-type": "cluster", "platform.example.org/hosts-workloads": "true"},
        annotations: .metadata.annotations}
      | .data.name = ($n | @base64) | .data.server = ($s | @base64)' \
  | kubectl apply -f - >/dev/null
for as in components-workloads components-control-plane tenancy-workloads tenancy-control-plane; do
  kubectl -n argocd annotate applicationset "$as" argocd.argoproj.io/application-set-refresh=true --overwrite >/dev/null
done

want_w="$(cd "$ROOT/platform/components" && ls */workloads.yaml | cut -d/ -f1 | sort)"
want_t="$(cd "$ROOT/platform/tenancy/teams" && ls *.yaml | sed 's/\.yaml$//' | sort)"
got=""
for _ in $(seq 1 36); do
  got="$(kubectl -n argocd get applications -o json | jq -r --arg s "$SERVER" \
    '[.items[] | select(.spec.destination.server == $s) | .metadata.labels["platform.example.org/component"] // .metadata.name] | sort | .[]')"
  [ "$(echo "$got" | grep -c .)" -ge "$(( $(echo "$want_w" | grep -c .) + $(echo "$want_t" | grep -c .) ))" ] && break
  sleep 5
done
for c in $want_w; do
  echo "$got" | grep -qx "$c" && echo "PASS workloads component $c targets the workloads-only cluster" || { echo "FAIL $c not rendered for the workloads-only cluster"; fail=1; }
done
for t in $want_t; do
  echo "$got" | grep -qx "tenancy-$t-workloads" && echo "PASS tenancy-$t-workloads targets the workloads-only cluster" || { echo "FAIL tenancy-$t-workloads missing"; fail=1; }
done
for c in $(cd "$ROOT/platform/components" && ls */control-plane.yaml | cut -d/ -f1); do
  echo "$got" | grep -qx "$c" && { echo "FAIL control-plane component $c was rendered onto a workloads-only cluster"; fail=1; } || echo "PASS control-plane component $c not rendered for it"
done
echo "$got" | grep -q -- '-control-plane$' && { echo "FAIL a control-plane tenancy render targets the workloads-only cluster"; fail=1; } || echo "PASS no control-plane tenancy render targets it"
exit $fail
