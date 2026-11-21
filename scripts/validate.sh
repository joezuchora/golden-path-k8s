#!/usr/bin/env bash
# validate.sh: `make validate`, every static check (CLAUDE.md "Commands"). Offline except for schema downloads.
#   schemas      kubeconform on every rendered chart (CRD schemas from a pinned CRDs-catalog commit)
#   helm         helm lint on every chart
#   crossplane   crossplane resource validate (XRDs + compositions) and composition render golden files (D-040)
#   invariants   CLAUDE.md invariants that a lint can prove
#   tofu         OpenTofu fmt/validate (no roots until Phase 4: explicit SKIP)
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
      helm dependency build "$c" >/dev/null 2>&1 || true
      if ! helm template "$(basename "$c")" "$c" "${vf[@]}" >"$W/comp-$(basename "$c")-$p.yaml" 2>"$W/err"; then
        rm -f "$W/comp-$(basename "$c")-$p.yaml"
        if [ "$p" = kind ] || [ -f "$c/values-$p.yaml" ]; then fail "render $c ($p): $(head -3 "$W/err")"
        else printf 'INFO  %s: no %s profile yet (no values-%s.yaml, Phase 4): %s\n' "$c" "$p" "$p" "$(head -1 "$W/err" | cut -c1-120)"; fi
      fi
    done
  done
  for t in platform/tenancy/teams/*.yaml; do
    for cap in control-plane workloads; do
      helm template t platform/tenancy/chart -f platform/tenancy/chart/values.yaml -f platform/tenancy/chart/values-kind.yaml \
        -f platform/policies/verified-bases.yaml -f "$t" --set capability=$cap \
        --set global.platform.gitBase=http://gitea-http.gitea.svc:3000 \
        --set global.platform.platformRepo=http://gitea-http.gitea.svc:3000/x/y.git >"$W/tenancy-$(basename "$t" .yaml)-$cap.yaml" 2>"$W/err" \
        || fail "render tenancy $t ($cap): $(head -3 "$W/err")"
    done
  done
  for p in kind managed byo; do
    helm template hello charts/golden-service -n team-a-dev -f charts/golden-service/values-$p.yaml \
      -f charts/golden-service/ci/full-values.yaml >"$W/gs-$p.yaml" 2>"$W/err" || fail "render golden-service ($p): $(head -3 "$W/err")"
  done
}

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
helm template xp "$xp" -f "$xp/values-managed.yaml" --show-only templates/platform.yaml | yq 'select(.kind == "Provider")' >"$S/providers.yaml"
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
# ApplicationSets select clusters on exactly one capability label, never a name (D-023).
for f in platform/appsets/*.yaml platform/tenancy/chart/templates/control-plane.yaml; do
  grep -qE '^\s+- clusters:' "$f" || continue
  keys="$(grep -A4 -E '^\s+- clusters:' "$f" | grep -oE 'platform\.example\.org/hosts-(control-plane|workloads)' | sort -u | wc -l | tr -d ' ')"
  if grep -A6 -E '^\s+- clusters:' "$f" | grep -qE '^\s+(name|server):|values:'; then fail "$f: cluster generator selects on a name/server"
  elif [ "$keys" != 1 ] && [ "$(grep -cE '^\s+- clusters:' "$f")" = 1 ]; then fail "$f: cluster generator must select on exactly one capability label"
  fi
done; pass "ApplicationSets select on capability labels only (D-023)"
# Component chart dependency versions equal tools/versions.env (D-039).
declare -A want=([cert-manager]=$CERT_MANAGER_CHART_VERSION [kyverno]=$KYVERNO_CHART_VERSION [external-secrets]=$ESO_CHART_VERSION \
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

hdr "tofu"
if compgen -G "infra/envs/*/*.tf" >/dev/null || compgen -G "infra/modules/*/*.tf" >/dev/null; then
  tofu fmt -recursive -check infra && pass "tofu fmt" || fail "tofu fmt"
  tflint --recursive --chdir infra && pass "tflint" || fail "tflint"
else printf 'INFO  no OpenTofu roots until Phase 4 (infra/envs/): tofu checks not applicable\n'; fi

printf '\nvalidate: %d failed, %d skipped\n' "$fails" "$skips"
[ "$fails" -eq 0 ]
