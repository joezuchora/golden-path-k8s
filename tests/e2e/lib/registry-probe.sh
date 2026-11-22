#!/usr/bin/env bash
# registry-probe.sh: when a Crossplane package isn't Healthy, print why, then time the paths to its registry (D-093).
# Crossplane's package manager fetches packages itself, from its own pod, not through the node's containerd. So the probe
# runs from a pod on Crossplane's node (pod network) and from that node (node network), against xpkg.crossplane.io and,
# as a control, ghcr.io. xpkg appears to be a proxy in front of GHCR (AWS addresses, ghcr.io auth realm; observed
# 2026-11-22). If only the pod fails, suspect in-cluster egress; if only xpkg fails, suspect xpkg's proxy.
# Creates one short-lived pod in its own namespace; changes nothing else.
# Usage (kind): KUBECONFIG=.kube/golden-path.yaml bash tests/e2e/lib/registry-probe.sh  (CI runs it on failure)
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/client.sh"   # CURL_IMAGE: the digest-pinned client image the journeys use
set +e
export MSYS_NO_PATHCONV=1
PKGS=functions.pkg.crossplane.io,providers.pkg.crossplane.io

echo "--- Crossplane packages"
kubectl get "$PKGS" -o wide 2>/dev/null
unhealthy="$(kubectl get "$PKGS" -o json 2>/dev/null | jq -r '.items[]
  | select(any(.status.conditions[]?; .type == "Healthy" and .status == "True") | not) | "\(.kind)/\(.metadata.name)"')"
[ -n "$unhealthy" ] || { echo "every Crossplane package is Healthy; registry probe skipped"; exit 0; }
kubectl get "$PKGS",functionrevisions.pkg.crossplane.io,providerrevisions.pkg.crossplane.io -o json 2>/dev/null | jq -r '.items[]
  | "\(.kind)/\(.metadata.name): " + ([.status.conditions[]? | "\(.type)=\(.status) \(.reason // "") \(.message // "")"] | join(" | "))'

node="$(kubectl -n crossplane-system get pods -l app=crossplane -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)"
# shellcheck disable=SC2016  # expanded by the probe's shell, not this one
probe='for u in https://xpkg.crossplane.io/v2/ https://ghcr.io/v2/; do for i in 1 2 3; do
  curl -sS -o /dev/null --max-time 15 -w "$u try $i: ip=%{remote_ip} dns=%{time_namelookup}s connect=%{time_connect}s tls=%{time_appconnect}s total=%{time_total}s http=%{http_code}\n" "$u" 2>&1
done; done'

echo "--- pod network, node ${node:-any} (Crossplane's path)"
ns=registry-probe
kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
overrides='{"apiVersion":"v1","spec":{}}'
[ -z "$node" ] || overrides="{\"apiVersion\":\"v1\",\"spec\":{\"nodeName\":\"$node\"}}"
kubectl -n "$ns" run probe --image "$CURL_IMAGE" --restart=Never --overrides "$overrides" --command -- sh -c "$probe" >/dev/null
kubectl -n "$ns" wait --for=jsonpath='{.status.phase}'=Succeeded pod/probe --timeout=180s >/dev/null \
  || { echo "probe pod didn't finish:"; kubectl -n "$ns" describe pod probe | tail -15; }
kubectl -n "$ns" logs probe
kubectl delete namespace "$ns" --wait=false >/dev/null

if [ -n "$node" ] && docker exec "$node" sh -c 'command -v curl' >/dev/null 2>&1; then
  echo "--- node network, $node (containerd's path)"
  docker exec "$node" sh -c 'getent ahosts xpkg.crossplane.io | head -3'
  docker exec "$node" sh -c "$probe"
else echo "--- node network: skipped (no Crossplane node, or no curl in the node image)"; fi
exit 0
