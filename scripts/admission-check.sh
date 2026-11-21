#!/usr/bin/env bash
# admission-check.sh <image@digest> [expect=pass|fail]: evaluate one image against the image-admission policy exactly as
# the cluster renders it for the test team (team-a), with kyverno test (online: GHCR + Rekor, F35).
# Used by build-hello's admission-self-check job (F41) and handy locally:  bash scripts/admission-check.sh <image>
# The kind profile is always checked; the AKS profile too when the image was built from main or a v1 tag.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$ROOT/.bin:$PATH"
IMAGE="${1:?usage: $0 <image@sha256:digest> [pass|fail]}"
EXPECT="${2:-pass}"
case "$IMAGE" in *@sha256:*) ;; *) echo "FAIL: pass an image by digest"; exit 2 ;; esac
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
profiles=(kind)
case "${GITHUB_REF:-}" in refs/heads/main|refs/tags/v1*) profiles+=(aks) ;; esac
fail=0
for profile in "${profiles[@]}"; do
  extra=(); [ "$profile" = kind ] && extra=(-f "$ROOT/platform/tenancy/chart/values-kind.yaml")
  helm template t "$ROOT/platform/tenancy/chart" -f "$ROOT/platform/tenancy/chart/values.yaml" "${extra[@]}" \
    -f "$ROOT/platform/policies/verified-bases.yaml" -f "$ROOT/platform/tenancy/teams/team-a.yaml" \
    --set capability=workloads --show-only templates/policies.yaml >"$W/policy.yaml"
  cat >"$W/pod.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: candidate
  namespace: team-a-dev
  ownerReferences: [{apiVersion: apps/v1, kind: ReplicaSet, name: candidate, uid: 00000000-0000-0000-0000-000000000001, controller: true}]
spec: {containers: [{name: app, image: "$IMAGE"}]}
EOF
  cp "$ROOT/platform/policies/tests/image-admission/values.yaml" "$ROOT/platform/policies/tests/image-admission/userinfo.yaml" "$W/"
  cat >"$W/kyverno-test.yaml" <<EOF
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata: {name: admission-check}
policies: [policy.yaml]
resources: [pod.yaml]
variables: values.yaml
userinfo: userinfo.yaml
results:
  - {policy: image-admission-team-a, resources: [candidate], kind: Pod, result: $EXPECT}
EOF
  echo "== image-admission-team-a ($profile profile), expect $EXPECT: $IMAGE"
  kyverno test "$W" --remove-color --detailed-results || fail=1
done
exit $fail
