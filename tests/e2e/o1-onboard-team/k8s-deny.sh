#!/usr/bin/env bash
# Cross-tenant deny, Kubernetes API (D-025). Identities are impersonated groups (kind substitute, D-050).
set -euo pipefail
fail=0
check() { # expected user group verb resource [namespace]
  local got
  if [ -n "${6:-}" ]; then got="$(kubectl auth can-i "$4" "$5" -n "$6" --as "$2" --as-group "$3" 2>/dev/null || true)"
  else got="$(kubectl auth can-i "$4" "$5" --as "$2" --as-group "$3" 2>/dev/null || true)"; fi
  if [ "$got" = "$1" ]; then echo "PASS $3: $4 $5 in ${6:-<cluster>} → $got"
  else echo "FAIL $3: $4 $5 in ${6:-<cluster>} → $got (expected $1)"; fail=1; fi
}
check yes dev-a team-a get pods team-a-dev
check yes dev-a team-a get pods/log team-a-dev
check yes dev-a team-a get pods tenant-team-a-dev
check no  dev-a team-a get pods team-b-dev
check no  dev-a team-a get pods tenant-team-b-dev
check no  dev-a team-a get secrets team-a-dev          # brokered credentials aren't readable by developers
check no  dev-a team-a create deployments team-a-dev   # changes go through Git, never kubectl apply
check no  dev-a team-a list namespaces                 # no cluster-scoped reads
check yes dev-b team-b get pods team-b-dev
check no  dev-b team-b get pods team-a-dev
check yes dev-c team-c get pods team-c-dev
check no  dev-c team-c get pods team-a-dev
# A real request, not only the authorizer's answer:
if out="$(kubectl get pods -n team-b-dev --as dev-a --as-group team-a 2>&1)"; then
  echo "FAIL team-a listed team-b pods: $out"; fail=1
elif echo "$out" | grep -q Forbidden; then echo "PASS team-a list pods in team-b-dev → Forbidden"
else echo "FAIL unexpected error: $out"; fail=1; fi
exit $fail
