#!/usr/bin/env bash
# bootstrap.sh: create the kind cluster and install what must exist before GitOps can run (D-016).
# Everything after Argo CD is reconciled from Git; this script only lays the foundation.
#
# Stages: preflight → cluster → gateway-api CRDs → cilium. Later stages (gitea, argo) are added as they're built.
# Usage: bash infra/kind/bootstrap.sh up|down|preflight|sync-git
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PATH="$ROOT/.bin:$PATH"
while IFS='=' read -r k val; do
  [[ $k =~ ^[A-Z0-9_]+$ ]] || continue
  [ -n "${!k:-}" ] || printf -v "$k" '%s' "$val"
done <"$ROOT/tools/versions.env"

CLUSTER=golden-path
CTX="kind-$CLUSTER"
MIN_MEM_GIB="${MIN_MEM_GIB:-8}"   # measured peak 5.97 GiB (F49)
k() { kubectl --context "$CTX" "$@"; }
step() { printf '\n==> %s\n' "$*"; }

preflight() {
  step "preflight"
  command -v docker >/dev/null || { echo "FAIL: docker CLI not found"; exit 1; }
  docker info >/dev/null 2>&1 || { echo "FAIL: Docker engine not reachable. Start Docker Desktop (or the engine) and retry."; exit 1; }
  local mem cg
  mem="$(docker info --format '{{.MemTotal}}')"; cg="$(docker info --format '{{.CgroupVersion}}')"
  local gib; gib="$(awk -v m="$mem" 'BEGIN{printf "%.1f", m/1073741824}')"
  echo "Docker: $(docker info --format '{{.ServerVersion}}'), memory ${gib} GiB, CPUs $(docker info --format '{{.NCPU}}'), cgroup v$cg"
  awk -v g="$gib" -v min="$MIN_MEM_GIB" 'BEGIN{exit !(g+0 >= min+0)}' \
    || { echo "FAIL: Docker has ${gib} GiB; the kind platform needs at least ${MIN_MEM_GIB} GiB. Raise the Docker/WSL memory limit."; exit 1; }
  [ "$cg" = "2" ] || { echo "FAIL: cgroup v$cg; Cilium's socket-LB on kind needs cgroup v2 (F30)."; exit 1; }
  for t in kind kubectl helm; do command -v "$t" >/dev/null || { echo "FAIL: $t missing; run 'make tools'"; exit 1; }; done
  echo "PASS preflight"
}

cluster() {
  step "kind cluster $CLUSTER ($KIND_NODE_IMAGE)"
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
    echo "exists; exporting its kubeconfig context $CTX"
    kind export kubeconfig --name "$CLUSTER"
  else
    kind create cluster --config "$ROOT/infra/kind/cluster.yaml" --image "$KIND_NODE_IMAGE" --wait 0s
  fi
}

gateway_api() {
  step "Gateway API CRDs $GATEWAY_API_VERSION (standard channel)"
  k apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/standard-install.yaml"
}

cilium() {
  step "Cilium $CILIUM_CHART_VERSION"
  helm --kube-context "$CTX" upgrade --install cilium oci://quay.io/cilium/charts/cilium --version "$CILIUM_CHART_VERSION" \
    --namespace kube-system \
    -f "$ROOT/platform/components/cilium/values.yaml" -f "$ROOT/platform/components/cilium/values-kind.yaml" --wait --timeout 10m
  k -n kube-system rollout status ds/cilium --timeout=5m
  k wait --for=condition=Ready nodes --all --timeout=5m
  lb_pool
}

lb_pool() {
  # Gateway LoadBalancer IPs come from the top of the kind Docker network. Docker picks that network's subnet when kind
  # first creates it (F37), so the pool is derived from the real subnet rather than assumed.
  local sub; sub="$(docker network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -E '^[0-9.]+/16$' | head -1)"
  [ -n "$sub" ] || { echo "FAIL: the kind network has no IPv4 /16 subnet ($(docker network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}')); see docs/getting-started.md (subnet clashes)"; exit 1; }
  local prefix; prefix="$(echo "$sub" | cut -d. -f1-2)"
  echo "kind network $sub → Gateway pool $prefix.255.200-$prefix.255.250"
  sed -e "s/172\.18\./$prefix./g" "$ROOT/platform/components/cilium/lb-pool-kind.yaml" | k apply -f -
}

gitea() {
  step "Gitea $GITEA_CHART_VERSION (kind Git host, D-043)"
  k create namespace gitea --dry-run=client -o yaml | k apply -f - >/dev/null
  if ! k -n gitea get secret gitea-admin >/dev/null 2>&1; then
    k -n gitea create secret generic gitea-admin --from-literal=username=gitea_admin       --from-literal=password="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)Aa1!" >/dev/null
  fi
  helm --kube-context "$CTX" upgrade --install gitea gitea --repo https://dl.gitea.com/charts/ --version "$GITEA_CHART_VERSION"     --namespace gitea -f "$ROOT/platform/bootstrap/gitea-values-kind.yaml" --wait --timeout 10m
}

argocd() {
  step "Argo CD chart $ARGOCD_CHART_VERSION"
  helm --kube-context "$CTX" upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm --version "$ARGOCD_CHART_VERSION"     --namespace argocd --create-namespace     -f "$ROOT/platform/bootstrap/argocd-values.yaml" -f "$ROOT/platform/bootstrap/argocd-values-kind.yaml" --wait --timeout 10m
}

seed_git() {
  step "seed Gitea (platform snapshot, team deploy repos, notification bot)"
  # shellcheck disable=SC1091
  . "$ROOT/infra/kind/gitea.sh"
  gitea_open; seed; gitea_close
}

gitops() {
  step "GitOps: platform project, cluster Secret (both capabilities, D-023), root app"
  k apply -f "$ROOT/platform/bootstrap/project-platform.yaml" -f "$ROOT/platform/bootstrap/cluster-kind.yaml" -f "$ROOT/platform/bootstrap/root-kind.yaml"
}

case "${1:-up}" in
  preflight) preflight ;;
  up) preflight; cluster; gateway_api; cilium; gitea; argocd; seed_git; gitops; step "kind-up done (Argo CD now reconciles the platform from Gitea)"; k get nodes -o wide ;;
  sync-git) argocd; seed_git ;;   # after a local change: re-apply Argo CD's bootstrap-owned values, push the tracked tree to Gitea
  down) kind delete cluster --name "$CLUSTER" ;;
  *) echo "usage: $0 up|down|preflight|sync-git"; exit 2 ;;
esac
