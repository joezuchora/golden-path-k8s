#!/usr/bin/env bash
# validate.sh: `make validate`, every static check (CLAUDE.md "Commands"). Offline except for schema downloads.
#   schemas      kubeconform on every rendered chart (CRD schemas from a pinned CRDs-catalog commit)
#   helm         helm lint on every chart
#   crossplane   crossplane resource validate (XRDs + compositions) and composition render golden files (D-040)
#   invariants   CLAUDE.md invariants that a lint can prove
#   terraform    terraform fmt, init (no backend) + validate per env root, provider lock coverage, tag lint, tflint
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$ROOT/.bin:$PATH"
cd "$ROOT"
while IFS='=' read -r k val; do [[ $k =~ ^[A-Z0-9_]+$ ]] && { [ -n "${!k:-}" ] || printf -v "$k" '%s' "$val"; }; done <tools/versions.env
CRDS_CATALOG="${CRDS_CATALOG:-c86448cbf1a840ca62d119259864863897c8748a}"   # datreeio/CRDs-catalog, 2026-11-05 (D-039 age rule)
K8S_SCHEMA_VERSION="${K8S_SCHEMA_VERSION:-1.37.0}"   # = the kind node image (tools/versions.env)
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fails=0; skips=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; fails=$((fails+1)); }
# REQUIRE_ALL=1 (CI) turns every SKIP into a FAIL, so a required check can't pass by not running (D-069).
skip() { if [ "${REQUIRE_ALL:-0}" = 1 ]; then fail "required but skipped: $*"; else printf 'SKIP  %s\n' "$*"; skips=$((skips+1)); fi; }
hdr()  { printf '\n== %s\n' "$*"; }

render_all() { # name → rendered file, for every chart the platform ships, per profile
  local c p
  for c in platform/components/*/; do
    c="${c%/}"; [ -f "$c/Chart.yaml" ] || continue
    for p in kind managed byo; do
      local vf=(-f "$c/values.yaml"); [ -f "$c/values.yaml" ] || vf=()
      [ -f "$c/values-$p.yaml" ] && vf+=(-f "$c/values-$p.yaml")
      [ "$p" != kind ] && vf+=(-f scripts/ci/platform-values-aks.yaml)   # the AKS cluster Secret's platform-values (D-081)
      if ! helm template "$(basename "$c")" "$c" "${vf[@]}" >"$W/comp-$(basename "$c")-$p.yaml" 2>"$W/err"; then
        rm -f "$W/comp-$(basename "$c")-$p.yaml"
        if [ "$p" = kind ] || [ -f "$c/values-$p.yaml" ]; then fail "render $c ($p): $(head -3 "$W/err")"
        else printf 'INFO  %s: no %s profile yet (no values-%s.yaml, Phase 4): %s\n' "$c" "$p" "$p" "$(head -1 "$W/err" | cut -c1-120)"; fi
      fi
    done
  done
  # Components guarded by controlPlaneOnly (D-078) render nothing above; render their split-AKS mode too.
  for c in $(grep -l 'condition: global.platform.controlPlaneOnly' platform/components/*/Chart.yaml | xargs -n1 dirname); do
    helm template "$(basename "$c")" "$c" -f "$c/values.yaml" --set global.platform.controlPlaneOnly=true \
      >"$W/comp-$(basename "$c")-control-plane-only.yaml" 2>"$W/err" || fail "render $c (controlPlaneOnly): $(head -3 "$W/err")"
  done
  for t in platform/tenancy/teams/*.yaml; do
    for cap in control-plane workloads; do
      helm template t platform/tenancy/chart -f platform/tenancy/chart/values.yaml -f platform/tenancy/chart/values-kind.yaml \
        -f platform/policies/verified-bases.yaml -f "$t" --set capability=$cap \
        --set global.platform.gitBase=http://gitea-http.gitea.svc:3000 \
        --set global.platform.platformRepo=http://gitea-http.gitea.svc:3000/x/y.git >"$W/tenancy-$(basename "$t" .yaml)-$cap.yaml" 2>"$W/err" \
        || fail "render tenancy $t ($cap): $(head -3 "$W/err")"
      # AKS profile (D-078, D-080, D-081): keyvault backend and GitHub deploy repos, with test identities for every env.
      yq -o json '{"azure": {"tenantId": "00000000-0000-0000-0000-000000000000", "tenants": ([.envs[] as $e |
          {"key": (.team + "-" + $e), "value": {"keyVaultUrl": "https://kv-test.vault.azure.net/",
           "writerClientId": "11111111-1111-1111-1111-111111111111", "readerClientId": "22222222-2222-2222-2222-222222222222"}}] | from_entries)}}' "$t" >"$W/tv.json"
      helm template t platform/tenancy/chart -f platform/tenancy/chart/values.yaml -f platform/tenancy/chart/values-managed.yaml \
        -f platform/policies/verified-bases.yaml -f "$t" -f "$W/tv.json" --set capability=$cap \
        --set global.platform.gitBase=https://github.com --set-string 'global.platform.deployRepoTemplate=joezuchora/gp-{team}-deploy' \
        --set global.platform.platformRepo=https://github.com/x/y.git >"$W/tenancy-$(basename "$t" .yaml)-$cap-managed.yaml" 2>"$W/err" \
        || fail "render tenancy $t ($cap, managed): $(head -3 "$W/err")"
    done
  done
  for p in kind managed byo; do
    helm template hello charts/golden-service -n team-a-dev -f charts/golden-service/values-$p.yaml \
      -f charts/golden-service/ci/full-values.yaml >"$W/gs-$p.yaml" 2>"$W/err" || fail "render golden-service ($p): $(head -3 "$W/err")"
  done
}

hdr "chart dependencies"
for c in platform/components/*/; do
  c="${c%/}"; [ "$(yq '.dependencies // [] | length' "$c/Chart.yaml" 2>/dev/null)" = 0 ] && continue
  [ -f "$c/Chart.yaml" ] || continue
  if [ ! -d "$c/charts" ]; then
    helm dependency update "$c" >"$W/dep" 2>&1 && pass "fetched $c dependencies (pinned in Chart.yaml)" || fail "helm dependency update $c: $(tail -2 "$W/dep")"
  fi
done
git diff --quiet -- 'platform/components/*/Chart.lock' && pass "every Chart.lock unchanged by the fetch" || fail "a Chart.lock changed: $(git diff --stat -- 'platform/components/*/Chart.lock' | tail -1)"

hdr "helm lint"
for c in charts/golden-service platform/tenancy/chart platform/components/*/; do
  c="${c%/}"; [ -f "$c/Chart.yaml" ] || continue
  args=(); [ -f "$c/values-kind.yaml" ] && args+=(-f "$c/values-kind.yaml")
  case "$c" in
    charts/golden-service) args+=(-f charts/golden-service/ci/full-values.yaml --namespace team-a-dev) ;;
    platform/tenancy/chart) args+=(-f platform/tenancy/teams/team-a.yaml --set capability=workloads) ;;
  esac
  if out="$(helm lint "$c" "${args[@]}" 2>&1)"; then pass "helm lint $c"; else fail "helm lint $c: $(echo "$out" | grep -E 'ERROR|Error' | head -3)"; fi
done

hdr "render"
render_all
pass "rendered $(ls "$W" | grep -c '\.yaml$') manifests (components × profiles, tenancy × teams × capabilities, golden-service × modes)"

hdr "schemas (kubeconform, Kubernetes $K8S_SCHEMA_VERSION + CRDs-catalog@${CRDS_CATALOG:0:7})"
if out="$(kubeconform -strict -summary -kubernetes-version "$K8S_SCHEMA_VERSION" -schema-location default \
     -schema-location "https://raw.githubusercontent.com/datreeio/CRDs-catalog/$CRDS_CATALOG/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
     -ignore-missing-schemas "$W"/*.yaml platform/appsets/*.yaml $(ls platform/bootstrap/*.yaml | grep -v values) 2>&1)"; then
  pass "kubeconform: $(echo "$out" | tail -1)"
  echo "INFO  kubeconform 'Skipped' counts objects whose CRD has no schema in the pinned catalog; those objects are not schema-validated"
else fail "kubeconform:"; echo "$out" | grep -vE '^$' | tail -15 | sed 's/^/        /'; fi

hdr "crossplane (D-040)"
xp=platform/components/crossplane-config
S="$W/xp-schemas"; mkdir -p "$S"
helm template xp "$xp" -f "$xp/values-kind.yaml" --show-only templates/platform.yaml | yq 'select(.kind == "CompositeResourceDefinition")' >"$S/xrds.yaml"
for c in cloudnative-pg external-secrets; do
  helm template x "platform/components/$c" --include-crds -f "platform/components/$c/values.yaml" 2>/dev/null | yq 'select(.kind == "CustomResourceDefinition")' >"$S/crds-$c.yaml"
done
helm template xp "$xp" -f "$xp/values-managed.yaml" -f scripts/ci/platform-values-aks.yaml --show-only templates/platform.yaml | yq 'select(.kind == "Provider")' >"$S/providers.yaml"
for prov in local azure; do
  [ -f "$xp/compositions/$prov/postgresqlinstance.yaml" ] || fail "XRD postgresqlinstances has no $prov composition (CLAUDE.md: every XRD needs azure and local)"
done
if docker info >/dev/null 2>&1; then
  for g in "$xp"/render-tests/*/; do
    g="${g%/}"; prov="$(basename "$g")"
    args=(--required-resources "$g/required.yaml"); [ -f "$g/observed.yaml" ] && args+=(--observed-resources "$g/observed.yaml")
    if ! crossplane composition render "$g/xr.yaml" "$xp/compositions/$prov/postgresqlinstance.yaml" "$xp/render-tests/functions.yaml" \
         "${args[@]}" >"$W/render-$prov.yaml" 2>"$W/err"; then fail "composition render ($prov): $(tail -3 "$W/err")"; continue; fi
    if diff -u "$g/expected.yaml" "$W/render-$prov.yaml" >"$W/diff"; then pass "composition render ($prov) matches render-tests/$prov/expected.yaml"
    else fail "composition render ($prov) differs from its golden file:"; head -30 "$W/diff" | sed 's/^/        /'; fi
    if out="$(crossplane resource validate "$S" "$W/render-$prov.yaml" 2>&1)"; then pass "crossplane resource validate ($prov): $(echo "$out" | tail -1)"
    else fail "crossplane resource validate ($prov):"; echo "$out" | grep -E '^\[x\]|error' | head -10 | sed 's/^/        /'; fi
  done
else skip "crossplane composition render and resource validate need Docker (F26): not run"; fi

hdr "invariants (CLAUDE.md)"
# Kyverno policy set v1 is CEL-only (D-042).
if grep -rlE '^kind: (ClusterPolicy|Policy)$' platform charts >/dev/null 2>&1; then fail "ClusterPolicy/Policy found: $(grep -rlE '^kind: (ClusterPolicy|Policy)$' platform charts | tr '\n' ' ')"
else pass "no ClusterPolicy/Policy (D-042)"; fi
# Placement: exactly one capability file per component (D-023).
for c in platform/components/*/; do
  n="$(ls "$c" | grep -cE '^(control-plane|workloads|bootstrap)\.yaml$')"
  [ "$n" = 1 ] || fail "$c has $n placement files (need exactly one of control-plane.yaml, workloads.yaml, bootstrap.yaml)"
done; pass "every component has exactly one placement file (D-023)"
# ApplicationSets select clusters on exactly one capability label, never a name (D-023). The only other selector key is the
# workload group, and only next to hosts-workloads (D-079). Checked on the rendered ApplicationSets.
plbad=0
for f in platform/appsets/*.yaml "$W"/tenancy-*.yaml; do
  out="$(yq -o json -I0 'select(.kind == "ApplicationSet") | .. | select(tag == "!!map") | select(has("clusters")) | .clusters.selector' "$f" 2>/dev/null \
    | jq -r --arg f "$(basename "$f")" '(.matchLabels // {} | keys) as $k
        | ($k | map(select(startswith("platform.example.org/hosts-"))) | length) as $cap
        | if ((.matchExpressions // []) | length) > 0 then "\($f): matchExpressions in a cluster selector"
          elif $cap != 1 then "\($f): selects on \($k) (need exactly one capability label)"
          elif ($k - ["platform.example.org/hosts-control-plane", "platform.example.org/hosts-workloads", "platform.example.org/workload-group"] | length) > 0 then "\($f): selects on \($k) (only a capability label and the workload group)"
          elif ($k | index("platform.example.org/workload-group")) != null and ($k | index("platform.example.org/hosts-workloads")) == null then "\($f): workload-group without hosts-workloads"
          else empty end')"
  [ -z "$out" ] || { fail "$out"; plbad=1; }
done
[ $plbad = 0 ] && pass "ApplicationSets select on one capability label (+ the workload group for team apps) (D-023, D-079)"
# Team app Applications are unique per cluster (D-079): the name carries the cluster's name.
for f in "$W"/tenancy-*-control-plane.yaml "$W"/tenancy-*-control-plane-managed.yaml; do
  n="$(yq -r 'select(.kind == "ApplicationSet" and (.metadata.name | test("^apps-"))) | .spec.template.metadata.name' "$f")"
  case "$n" in *'{{ .name }}'*) ;; *) fail "$(basename "$f"): team app name '$n' has no cluster component (D-079)" ;; esac
done; pass "team app Application names include the cluster (D-079)"
# Component chart dependency versions equal tools/versions.env (D-039).
declare -A want=([cert-manager]=$CERT_MANAGER_CHART_VERSION [kyverno]=$KYVERNO_CHART_VERSION [external-secrets]=$ESO_CHART_VERSION \
  [external-secrets-push]=$ESO_CHART_VERSION \
  [reloader]=$RELOADER_CHART_VERSION [crossplane]=$CROSSPLANE_CHART_VERSION [cloudnative-pg]=$CNPG_CHART_VERSION)
for c in "${!want[@]}"; do
  got="$(yq '.dependencies[0].version' "platform/components/$c/Chart.yaml")"
  [ "$got" = "${want[$c]}" ] && pass "$c chart $got = versions.env" || fail "$c chart $got != versions.env ${want[$c]}"
done
# Images: Chainguard bases only, digest-pinned (CLAUDE.md "Images").
for d in apps/*/Dockerfile; do
  bad="$(grep -E '^ARG (BUILDER|BASE)_IMAGE=' "$d" | grep -vE '=cgr\.dev/chainguard/[a-z0-9-]+:latest(-dev)?@sha256:[0-9a-f]{64}$' || true)"
  froms="$(grep -E '^FROM ' "$d" | grep -vE '^FROM \$\{(BUILDER|BASE)_IMAGE\}' || true)"
  [ -z "$bad$froms" ] && pass "$d: Chainguard :latest@sha256 bases only" || fail "$d: non-Chainguard or unpinned base: $bad $froms"
done
# Every image a chart renders is digest-pinned.
unpinned="$(cat "$W"/gs-*.yaml "$W"/tenancy-*.yaml | yq -N '.. | select(has("image")) | .image' 2>/dev/null | grep -v '@sha256:' | sort -u || true)"
[ -z "$unpinned" ] && pass "golden-service and tenancy render only digest-pinned images" || fail "unpinned images: $unpinned"
# golden-service renders identically in cilium_mode managed and byo (CLAUDE.md "cilium_mode").
if diff -q "$W/gs-managed.yaml" "$W/gs-byo.yaml" >/dev/null; then pass "golden-service: managed and byo renders are identical"
else fail "golden-service renders differ between managed and byo:"; diff "$W/gs-managed.yaml" "$W/gs-byo.yaml" | head -10; fi
# No tag / cost-center fields in the app surface (D-017).
if yq '.properties | keys | .[]' charts/golden-service/values.schema.json | grep -qiE '^(team|owner|cost.?center|costCenter|tags|labels)$'; then
  fail "golden-service schema exposes an ownership/tag field (D-017)"
else pass "golden-service schema has no team/owner/cost-center/tags fields (D-017)"; fi
if [ -s "$S/xrds.yaml" ]; then
  if yq "$S/xrds.yaml" | yq '.. | select(has("properties")) | .properties | keys | .[]' | grep -qiE '^(team|owner|costCenter|cost-center|tags)$'; then
    fail "an XRD schema exposes an ownership/tag field (D-017)"; else pass "XRD schemas have no team/owner/cost-center/tags fields (D-017)"; fi
fi
# GitHub Actions: every `uses:` of a remote action is pinned to a commit SHA; cosign checksum matches the lock.
bad="$(grep -hE '^\s*(- )?uses: ' .github/workflows/*.yaml | grep -vE 'uses: \./' | grep -vE '@[0-9a-f]{40}( |$)' || true)"
[ -z "$bad" ] && pass "every GitHub Action is pinned by commit SHA" || fail "actions not pinned by SHA: $bad"
# Workflows parse as YAML (GitHub rejects the whole file otherwise, and the checks below would silently see nothing).
for f in .github/workflows/*.yaml; do
  yq -e '.jobs' "$f" >/dev/null 2>"$W/err" && pass "$f parses" || fail "$f isn't valid YAML: $(head -1 "$W/err")"
  # A comma inside an unquoted flow-mapping value splits it into a stray null key, which GitHub's schema rejects.
  nulls="$(yq -o json '.' "$f" | jq -r 'paths(type == "null") | map(tostring) | join(".")')"
  [ -z "$nulls" ] || fail "$f has null values (stray keys from an unquoted comma?): $nulls"
done
# Workflows: no ${{ }} expression inside a run: script; values reach the shell through env: (D-069, GitHub script injection).
inj="$(for f in .github/workflows/*.yaml; do yq -r '.jobs[].steps[]? | select(.run != null) | .run' "$f" | grep -n '\${{' | sed "s|^|$f: |"; done || true)"
[ -z "$inj" ] && pass "no \${{ }} expressions inside workflow run: scripts (D-069)" || { fail "workflow scripts expand expressions directly (use env:):"; echo "$inj" | head -10 | sed 's/^/        /'; }
lock="$(awk -v v="$COSIGN_VERSION" '$1=="cosign" && $2==v && $3=="linux-amd64" {print $5}' tools/checksums.lock)"
wf="$(sed -n 's/^\s*COSIGN_SHA256: \([0-9a-f]*\).*/\1/p' .github/workflows/reusable-build-sign.yaml)"
[ -n "$lock" ] && [ "$lock" = "$wf" ] && pass "reusable-build-sign cosign checksum = tools/checksums.lock" || fail "cosign checksum in the workflow ($wf) != lock ($lock)"
# Repo coordinates appear only as rendered by render-repo-coords.sh (D-046).
if out="$(bash scripts/render-repo-coords.sh --check 2>&1)"; then pass "${out#PASS: }"; else fail "$out"; fi
# Every journey has an e2e suite (CLAUDE.md "journeys").
for j in docs/journeys/*.md; do
  [ -e "$j" ] || continue; [ "$(basename "$j")" = README.md ] && continue
  id="$(basename "$j" .md)"; [ -d "tests/e2e/$id" ] || fail "journey $id has no tests/e2e/$id"
done; pass "every docs/journeys page has a tests/e2e suite"

hdr "Argo CD notifications (D-043, D-067)"
# Argo CD parses each template and trigger as YAML before rendering it, so a YAML error silently disables every
# notification. Parse them the same way.
nbad=0
for key in $(yq -r '.notifications.templates // {} | keys | .[]' platform/bootstrap/argocd-values.yaml) $(yq -r '.notifications.triggers // {} | keys | .[]' platform/bootstrap/argocd-values.yaml); do
  sect=templates; case "$key" in trigger.*) sect=triggers ;; esac
  if ! yq -r ".notifications.$sect[\"$key\"]" platform/bootstrap/argocd-values.yaml | yq -e '.' >/dev/null 2>"$W/err"; then
    fail "notification $key isn't valid YAML: $(head -2 "$W/err")"; nbad=1
  fi
done
[ $nbad = 0 ] && pass "every Argo CD notification template and trigger parses as YAML"

hdr "terraform (D-083, D-088)"
# Static only: init without a backend downloads the pinned providers; nothing here talks to Azure.
if compgen -G "infra/envs/*/*.tf" >/dev/null; then
  terraform fmt -recursive -check infra >"$W/fmt" 2>&1 && pass "terraform fmt" || fail "terraform fmt: $(head -5 "$W/fmt" | tr '\n' ' ')"
  for e in infra/envs/*/; do
    e="${e%/}"
    if ! terraform -chdir="$e" init -backend=false -input=false -lockfile=readonly >"$W/init" 2>&1; then
      fail "terraform init $e (readonly lock): $(grep -iE 'error' "$W/init" | head -2)"; continue
    fi
    terraform -chdir="$e" validate -no-color >"$W/tv" 2>&1 && pass "terraform validate $e" || fail "terraform validate $e: $(grep -A3 -i error "$W/tv" | head -6 | tr '\n' ' ')"
    # The committed lock covers every platform tools/install.sh supports, so no contributor's init rewrites it.
    nh="$(grep -c '"h1:' "$e/.terraform.lock.hcl" || true)"
    [ "${nh:-0}" -ge 10 ] && pass "$e/.terraform.lock.hcl has $nh h1 hashes (5 platforms × providers)" || fail "$e/.terraform.lock.hcl has ${nh:-0} h1 hashes; run: terraform -chdir=$e providers lock -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_amd64 -platform=darwin_arm64 -platform=windows_amd64"
    # ADR-0007: every azurerm resource whose type supports tags sets tags (the provider schema decides what's taggable).
    terraform -chdir="$e" providers schema -json 2>/dev/null \
      | jq -r '.provider_schemas | to_entries[] | select(.key | endswith("/azurerm")) | .value.resource_schemas | to_entries[]
               | select(.value.block.attributes.tags != null) | .key' | tr -d '\r' | sort -u >"$W/taggable"
    [ -s "$W/taggable" ] || { fail "couldn't read the azurerm schema for the tag check ($e)"; continue; }
  done
  untagged="$(find infra -name '*.tf' -not -path '*/.terraform/*' -print0 | xargs -0 awk '
      FNR == 1 { depth = 0; t = "" }
      t == "" && match($0, /^resource "[a-z0-9_]+" "[^"]+"/) { split($0, a, "\""); t = a[2]; n = a[4]; depth = 0; has = 0; start = FNR }
      t != "" {
        line = $0; sub(/#.*/, "", line)
        if (depth == 1 && line ~ /^[ \t]*tags[ \t]*=/) has = 1
        o = gsub(/\{/, "{", line); c = gsub(/\}/, "}", line); depth += o - c
        if (depth == 0 && FNR >= start && (o + c) > 0) { print t, n, FILENAME ":" start, has; t = "" }
      }' | while read -r t n where has; do
        grep -qx "$t" "$W/taggable" && [ "$has" = 0 ] && echo "$t.$n ($where)"; done || true)"
  [ -z "$untagged" ] && pass "every taggable azurerm resource sets tags (ADR-0007)" || fail "taggable resources without tags (ADR-0007): $untagged"
  tflint --recursive --chdir infra >"$W/tflint" 2>&1 && pass "tflint" || fail "tflint: $(grep -E 'Warning|Error' "$W/tflint" | head -3 | tr '\n' ' ')"
else fail "no Terraform root under infra/envs/ (Phase 4 ships infra/envs/sandbox)"; fi

printf '\nvalidate: %d failed, %d skipped\n' "$fails" "$skips"
[ "$fails" -eq 0 ]
