#!/usr/bin/env bash
# aks.sh: the only way to create, bootstrap and tear down an AKS environment (D-083). Mirrors infra/kind/bootstrap.sh.
#
#   preflight        make doctor PROFILE=cloud (read-only; D-084)
#   plan             terraform plan for infra/envs/$GP_ENV → tfplan, and the run record
#   up               apply tfplan. Refuses unless GP_CONFIRM_SUBSCRIPTION equals the tfvars subscription, and runs under
#                    GP_APPLY_TIMEOUT (default 45m). A timeout or failure is a visible failure: run `down`.
#   bootstrap        install what must exist before GitOps: Gateway API CRDs (workload clusters), Argo CD with Workload
#                    Identity (control cluster), the cluster Secrets with their capability labels and per-environment
#                    annotations, the root application, the EnvironmentConfig for compositions, and the Git status token
#   down             delete the teams' applications and XRs (so Crossplane deletes what it composed), wait for every
#                    managed resource to go, terraform destroy under GP_DESTROY_TIMEOUT (default 45m), then verify-teardown
#   verify-teardown  assert from Azure itself (not from state) that nothing tagged with the environment id, no resource
#                    group of the run and no role assignment of its identities remains. Exit 1 lists what's left.
#
# Environment: GP_ENV (default sandbox), GP_PLATFORM_REVISION (default main), GP_DEPLOY_REPO_TEMPLATE (default
# <owner>/gp-{team}-deploy on GitHub, D-080), GP_GITHUB_STATUS_TOKEN (bootstrap: a fine-grained token with commit-status
# write on the deploy repos; read from the environment, never printed or written to disk).
# Every run appends to .e2e-reports/aks-<environment_id>.log: who, when, what, and the outcome.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PATH="$ROOT/.bin:$PATH"
while IFS='=' read -r k val; do [[ $k =~ ^[A-Z0-9_]+$ ]] || continue; [ -n "${!k:-}" ] || printf -v "$k" '%s' "$val"; done <"$ROOT/tools/versions.env"
# shellcheck disable=SC1091
. "$ROOT/repo-coords.env"
jq() { command jq "$@" | tr -d '\r'; }   # the Windows jq build ends lines with CRLF
az_() { az "$@" --only-show-errors | tr -d '\r'; }

GP_ENV="${GP_ENV:-sandbox}"
ENVDIR="$ROOT/infra/envs/$GP_ENV"
TFVARS="$ENVDIR/$GP_ENV.auto.tfvars"
REPORTS="$ROOT/.e2e-reports"
KUBEDIR="$ROOT/.kube"
REVISION="${GP_PLATFORM_REVISION:-main}"
DEPLOY_TEMPLATE="${GP_DEPLOY_REPO_TEMPLATE:-$REPO_OWNER/gp-{team}-deploy}"
PLATFORM_REPO="https://github.com/$REPO_OWNER/$REPO_NAME.git"
step() { printf '\n==> %s\n' "$*"; }
die() { echo "FAIL: $*" >&2; exit 1; }
tfv() { sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"?([^\"#]*[^\"#[:space:]])\"?.*$/\1/p" "$TFVARS" | head -1; }
tf_() { terraform -chdir="$ENVDIR" "$@"; }

[ -f "$TFVARS" ] || die "$TFVARS not found: copy $GP_ENV.tfvars.example and confirm every value with the environment owner"
ENV_ID="$(tfv environment_id)"; SUB="$(tfv subscription_id)"; OWNER="$(tfv teardown_owner)"
[ -n "$ENV_ID" ] && [ -n "$SUB" ] && [ -n "$OWNER" ] || die "tfvars needs environment_id, subscription_id and teardown_owner"
RECORD="$REPORTS/aks-$ENV_ID.json"   # non-secret outputs, kept outside the state so the teardown check survives losing it
mkdir -p "$REPORTS" "$KUBEDIR"
log() { printf '%s %s %s env=%s sub=%s owner=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(git -C "$ROOT" rev-parse --short HEAD)" "$1" \
  "$ENV_ID" "$SUB" "$OWNER" "${2:-}" >>"$REPORTS/aks-$ENV_ID.log"; }
with_timeout() { # <duration> <cmd…>: a hung apply or destroy becomes a visible failure
  local d=$1; shift
  if command -v timeout >/dev/null; then timeout --foreground "$d" "$@"; else "$@"; fi
}
kcfg() { echo "$KUBEDIR/aks-$ENV_ID-$1.yaml"; }
k() { local c=$1; shift; kubectl --kubeconfig "$(kcfg "$c")" "$@"; }
save_record() { tf_ output -json 2>/dev/null | jq '{environment: .environment.value, clusters: .clusters.value, tenants: .tenants.value}' >"$RECORD.tmp" \
  && [ -s "$RECORD.tmp" ] && [ "$(jq -r '.environment.environment_id' "$RECORD.tmp")" = "$ENV_ID" ] && mv "$RECORD.tmp" "$RECORD" || rm -f "$RECORD.tmp"; }

preflight() { step "cloud preflight (D-084)"; GP_ENV="$GP_ENV" bash "$ROOT/scripts/doctor.sh" cloud; }

plan() {
  preflight
  step "terraform plan ($ENVDIR)"
  az_ account set --subscription "$SUB"
  tf_ init -input=false -lockfile=readonly >/dev/null
  tf_ plan -input=false -out=tfplan
  log plan "ok"
}

up() {
  [ "${GP_CONFIRM_SUBSCRIPTION:-}" = "$SUB" ] || die "refusing to apply: set GP_CONFIRM_SUBSCRIPTION=$SUB to confirm the subscription (billable resources)"
  [ -f "$ENVDIR/tfplan" ] || die "no tfplan: run '$0 plan' first and review it"
  step "terraform apply (timeout ${GP_APPLY_TIMEOUT:-45m}, teardown owner $OWNER)"
  log up "start"
  if ! with_timeout "${GP_APPLY_TIMEOUT:-45m}" terraform -chdir="$ENVDIR" apply -input=false tfplan; then
    save_record; log up "FAILED or timed out"
    die "apply failed or timed out. Resources may exist: run '$0 down' (owner: $OWNER)"
  fi
  rm -f "$ENVDIR/tfplan"; save_record; log up "ok"
  echo "Run record: $RECORD. Next: $0 bootstrap"
}

kubeconfigs() {
  step "kubeconfigs (Entra ID via kubelogin; local accounts are disabled)"
  local rg c name
  rg="$(jq -r .environment.platform_rg "$RECORD")"
  for c in control $(jq -r '.clusters.workloads | keys[]' "$RECORD"); do
    if [ "$c" = control ]; then name="$(jq -r .clusters.control.name "$RECORD")"; else name="$(jq -r --arg c "$c" '.clusters.workloads[$c].name' "$RECORD")"; fi
    az_ aks get-credentials --subscription "$SUB" -g "$rg" -n "$name" --file "$(kcfg "$c")" --overwrite-existing >/dev/null
    kubelogin convert-kubeconfig -l azurecli --kubeconfig "$(kcfg "$c")"
    k "$c" get --raw /readyz >/dev/null && echo "  $c: $name reachable" || die "$c ($name) API server not reachable (is this machine's IP in api_server_authorized_ip_ranges?)"
  done
}

bootstrap() {
  [ -f "$RECORD" ] || save_record
  [ -f "$RECORD" ] || die "no run record ($RECORD): run '$0 up' first"
  local mode; mode="$(jq -r .environment.cilium_mode "$RECORD")"
  [ "$mode" = managed ] || die "cilium_mode=$mode: the byo bootstrap (OSS Cilium on AKS) is the next Phase 4 slice, after managed passes (D-087)"
  [ -n "${GP_GITHUB_STATUS_TOKEN:-}" ] || die "GP_GITHUB_STATUS_TOKEN is unset: Argo CD needs it to write commit statuses on the deploy repos (D-080)"
  log bootstrap "start"
  kubeconfigs
  local tenant sub argocd
  tenant="$(jq -r .environment.tenant_id "$RECORD")"; sub="$(jq -r .environment.subscription_id "$RECORD")"
  argocd="$(tf_ output -json identities | jq -r .argocd)"

  local c
  for c in $(jq -r '.clusters.workloads | keys[]' "$RECORD"); do
    step "workload cluster $c: Gateway API CRDs $GATEWAY_API_VERSION (standard channel)"
    k "$c" apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/standard-install.yaml" >/dev/null
  done

  step "control cluster: Argo CD chart $ARGOCD_CHART_VERSION with Workload Identity (D-085)"
  helm --kubeconfig "$(kcfg control)" upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm --version "$ARGOCD_CHART_VERSION" \
    --namespace argocd --create-namespace -f "$ROOT/platform/bootstrap/argocd-values.yaml" -f "$ROOT/platform/bootstrap/argocd-values-aks.yaml" \
    --set-string "controller.serviceAccount.annotations.azure\.workload\.identity/client-id=$argocd" \
    --set-string "controller.serviceAccount.annotations.azure\.workload\.identity/tenant-id=$tenant" \
    --set-string "server.serviceAccount.annotations.azure\.workload\.identity/client-id=$argocd" \
    --set-string "server.serviceAccount.annotations.azure\.workload\.identity/tenant-id=$tenant" \
    --wait --timeout 10m
  # The token comes from the environment and goes straight into the Secret: never echoed, never written to disk.
  k control -n argocd create secret generic argocd-notifications-secret --from-literal=git-token="$GP_GITHUB_STATUS_TOKEN" \
    --dry-run=client -o yaml | k control apply -f - >/dev/null
  echo "  argocd-notifications-secret applied (token from GP_GITHUB_STATUS_TOKEN)"
  k control apply -f "$ROOT/platform/bootstrap/project-platform.yaml" >/dev/null

  step "cluster Secrets: capability labels and per-environment annotations (D-023, D-079, D-081)"
  local pvals tvals
  # Crossplane has no identity of its own (D-099): each tenant's provider client ID goes to its namespaced ProviderConfig.
  pvals="$(jq -cn --arg t "$tenant" '{global: {azure: {tenantId: $t}}}')"
  tvals="$(jq -c --arg t "$tenant" --arg s "$sub" '{azure: {tenantId: $t, subscriptionId: $s,
    tenants: (.tenants | map_values({keyVaultUrl, writerClientId, readerClientId, providerClientId}))}}' "$RECORD")"
  cluster_secret control in-cluster https://kubernetes.default.svc '{"tlsClientConfig":{"insecure":false}}' \
    '{"platform.example.org/hosts-control-plane":"true"}' managed "$pvals" "$tvals"
  for c in $(jq -r '.clusters.workloads | keys[]' "$RECORD"); do
    local server group ca cfg
    server="$(jq -r --arg c "$c" '.clusters.workloads[$c].server' "$RECORD")"; group="$(jq -r --arg c "$c" '.clusters.workloads[$c].group' "$RECORD")"
    ca="$(tf_ output -json cluster_ca | jq -r --arg c "$c" '.[$c]')"
    # argocd-k8s-auth azure with workload identity (F55): the hub reaches the spoke with its federated identity, no kubeconfig.
    cfg="$(jq -cn --arg id "$argocd" --arg t "$tenant" --arg ca "$ca" '{execProviderConfig: {command: "argocd-k8s-auth", args: ["azure"],
      env: {AAD_ENVIRONMENT_NAME: "AzurePublicCloud", AZURE_CLIENT_ID: $id, AZURE_TENANT_ID: $t, AAD_LOGIN_METHOD: "workloadidentity"},
      apiVersion: "client.authentication.k8s.io/v1beta1"}, tlsClientConfig: {insecure: false, caData: $ca}}')"
    cluster_secret "$c" "$(jq -r --arg c "$c" '.clusters.workloads[$c].name' "$RECORD")" "$server" "$cfg" \
      "$(jq -cn --arg g "$group" '{"platform.example.org/hosts-workloads":"true","platform.example.org/workload-group":$g}')" "$mode" "$pvals" "$tvals"
  done

  step "root application ($PLATFORM_REPO @ $REVISION)"
  cat <<EOF | k control apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: platform-root, namespace: argocd}
spec:
  project: platform
  source: {repoURL: "$PLATFORM_REPO", targetRevision: "$REVISION", path: platform/appsets}
  destination: {server: https://kubernetes.default.svc, namespace: argocd}
  syncPolicy: {automated: {prune: true, selfHeal: true}}
EOF

  step "EnvironmentConfig azure-platform (compositions, D-082): waits for Crossplane's CRD"
  for _ in $(seq 1 90); do k control get crd environmentconfigs.apiextensions.crossplane.io >/dev/null 2>&1 && break; sleep 10; done
  k control get crd environmentconfigs.apiextensions.crossplane.io >/dev/null 2>&1 || die "Crossplane's EnvironmentConfig CRD didn't appear in 15 minutes: check the crossplane Application on the control cluster"
  jq -n --slurpfile r "$RECORD" --argjson pg "$(tf_ output -json postgres)" '{apiVersion: "apiextensions.crossplane.io/v1beta1", kind: "EnvironmentConfig",
      metadata: {name: "azure-platform"},
      data: {environmentId: $r[0].environment.environment_id, location: $r[0].environment.location, tenantId: $r[0].environment.tenant_id,
             postgresSubnetId: $pg.subnet_id,
             tenantResourceGroups: ($r[0].tenants | to_entries | map({key: .value.tenant_namespace, value: .value.resource_group}) | from_entries),
             tenantPostgresDnsZones: ($r[0].tenants | to_entries | map({key: .value.tenant_namespace, value: .value.postgresPrivateDnsZoneId}) | from_entries)}}' \
    | k control apply -f - >/dev/null
  log bootstrap "ok"
  echo "bootstrap done: Argo CD on the control cluster now reconciles the platform from $PLATFORM_REPO@$REVISION"
}

# cluster_secret <key> <name> <server> <config-json> <labels-json> <profile> <platform-values> <tenancy-values>
cluster_secret() {
  jq -n --arg key "$1" --arg name "$2" --arg server "$3" --arg config "$4" --argjson labels "$5" --arg profile "$6" \
     --arg pv "$7" --arg tv "$8" --arg repo "$PLATFORM_REPO" --arg rev "$REVISION" --arg tmpl "$DEPLOY_TEMPLATE" '{
    apiVersion: "v1", kind: "Secret", type: "Opaque",
    metadata: {name: ("cluster-" + $key), namespace: "argocd",
      labels: ({"argocd.argoproj.io/secret-type": "cluster"} + $labels),
      annotations: {"platform.example.org/profile": $profile, "platform.example.org/platform-repo": $repo,
        "platform.example.org/platform-revision": $rev, "platform.example.org/git-base": "https://github.com",
        "platform.example.org/deploy-repo-template": $tmpl,
        "platform.example.org/platform-values": $pv, "platform.example.org/tenancy-values": $tv}},
    stringData: {name: $name, server: $server, config: $config}}' | k control apply -f - >/dev/null
  echo "  cluster-$1 ($2): labels $(echo "$5" | jq -c 'keys'), profile $6"
}

down() {
  [ -f "$RECORD" ] || save_record
  log down "start"
  if [ -f "$(kcfg control)" ] && k control get --raw /readyz >/dev/null 2>&1; then
    step "delete the teams' applications (their finalizers prune apps and XRs), then wait for Crossplane to delete what it composed"
    k control -n argocd delete applications -l platform.example.org/team --wait=false >/dev/null 2>&1 || true
    k control -n argocd delete application platform-root --wait=false >/dev/null 2>&1 || true
    local left=""
    for _ in $(seq 1 120); do
      left="$(k control get managed -A -o name 2>/dev/null | grep -v 'providerconfigusage' || true)"
      [ -z "$left" ] && break; sleep 10
    done
    [ -z "$left" ] && echo "  no Crossplane managed resources left" \
      || { log down "managed resources still present"; die "Crossplane managed resources still exist after 20 minutes: $(echo "$left" | tr '\n' ' '). Fix them before destroy, or the tenant resource groups keep resources (owner: $OWNER)"; }
  else echo "  control cluster unreachable or never bootstrapped: skipping the XR drain (destroy fails if a tenant RG still holds resources)"; fi
  step "terraform destroy (timeout ${GP_DESTROY_TIMEOUT:-45m})"
  az_ account set --subscription "$SUB"
  tf_ init -input=false -lockfile=readonly >/dev/null
  if ! with_timeout "${GP_DESTROY_TIMEOUT:-45m}" terraform -chdir="$ENVDIR" destroy -input=false -auto-approve; then
    log down "destroy FAILED or timed out"; verify_teardown || true; die "destroy failed or timed out (owner: $OWNER)"
  fi
  rm -f "$KUBEDIR"/aks-"$ENV_ID"-*.yaml
  verify_teardown
  log down "ok"
}

verify_teardown() {
  step "verify teardown from Azure (environment-id=$ENV_ID, subscription $SUB)"
  [ -f "$RECORD" ] || die "no run record $RECORD: can't name the run's resource groups and identities (check by tag only: az resource list --tag environment-id=$ENV_ID)"
  local bad=0 n g p
  n="$(az_ resource list --subscription "$SUB" --tag "environment-id=$ENV_ID" --query 'length(@)' -o tsv)"
  [ "${n:-0}" = 0 ] && echo "PASS no resource tagged environment-id=$ENV_ID" \
    || { echo "FAIL $n resource(s) still tagged environment-id=$ENV_ID:"; az_ resource list --subscription "$SUB" --tag "environment-id=$ENV_ID" --query '[].id' -o tsv | sed 's/^/        /'; bad=1; }
  for g in $(jq -r '.environment | [.platform_rg] + .tenant_rgs + .node_rgs | .[]' "$RECORD"); do
    [ "$(az_ group exists --subscription "$SUB" -n "$g")" = false ] && echo "PASS resource group $g is gone" || { echo "FAIL resource group $g still exists"; bad=1; }
  done
  for p in $(jq -r '.environment.identity_principals[]' "$RECORD"); do
    n="$(az_ role assignment list --subscription "$SUB" --all --query "length([?principalId=='$p'])" -o tsv)"
    [ "${n:-0}" = 0 ] && echo "PASS no role assignment for identity $p" || { echo "FAIL $n role assignment(s) still reference identity $p"; bad=1; }
  done
  # Custom role definitions carry no tags, so the tag query above can't see them (D-099).
  for g in $(jq -r '.environment.custom_roles // [] | .[]' "$RECORD"); do
    n="$(az_ role definition list --subscription "$SUB" --custom-role-only true --name "$g" --query 'length(@)' -o tsv)"
    [ "${n:-0}" = 0 ] && echo "PASS custom role $g is gone" || { echo "FAIL custom role $g still exists"; bad=1; }
  done
  n="$(az_ keyvault list-deleted --subscription "$SUB" --query "length([?properties.tags.\"environment-id\"=='$ENV_ID'])" -o tsv)"
  [ "${n:-0}" = 0 ] && echo "PASS no soft-deleted Key Vault from this run" || { echo "FAIL $n soft-deleted Key Vault(s) from this run (az keyvault purge)"; bad=1; }
  [ $bad = 0 ] && { log verify-teardown "clean"; echo "teardown verified: nothing from $ENV_ID remains"; } || { log verify-teardown "LEFTOVERS"; return 1; }
}

case "${1:-}" in
  preflight) preflight ;;
  plan) plan ;;
  up) up ;;
  bootstrap) bootstrap ;;
  down) down ;;
  verify-teardown) verify_teardown ;;
  *) echo "usage: GP_ENV=<env> $0 preflight|plan|up|bootstrap|down|verify-teardown"; exit 2 ;;
esac
