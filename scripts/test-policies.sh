#!/usr/bin/env bash
# test-policies.sh: `make test-policies` (CLAUDE.md invariant: pass and fail cases for every policy).
#   1. Render the policy set exactly as the cluster gets it: kyverno-policies (cluster-wide) and the tenancy chart's
#      per-team instances for the test team (team-a), for both the kind and the AKS profile (D-055).
#   2. Check every policy has a test directory and a docs page, sets failurePolicy: Fail, and that every message gives
#      what failed, why, the fix and a docs link (ADR-0012).
#   3. kyverno test each directory. Image tests are online: they need GHCR and Rekor (F35).
set -euo pipefail
jq() { command jq "$@" | tr -d '\r'; }   # the Windows jq build ends lines with CRLF; strip it so values are safe in URLs
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$ROOT/.bin:$PATH"
T="$ROOT/platform/policies/tests"
R="$T/.rendered"
rm -rf "$R"; mkdir -p "$R"
helm template kp "$ROOT/platform/components/kyverno-policies" -f "$ROOT/platform/components/kyverno-policies/values.yaml" --show-only templates/policies.yaml >"$R/cluster.yaml"
for profile in kind aks; do
  extra=(); [ "$profile" = kind ] && extra=(-f "$ROOT/platform/tenancy/chart/values-kind.yaml")
  helm template t "$ROOT/platform/tenancy/chart" -f "$ROOT/platform/tenancy/chart/values.yaml" "${extra[@]}" \
    -f "$ROOT/platform/policies/verified-bases.yaml" -f "$ROOT/platform/tenancy/teams/team-a.yaml" \
    --set capability=workloads --show-only templates/policies.yaml >"$R/team-a-$profile.yaml"
done

fail=0
names="$(cat "$R/cluster.yaml" "$R/team-a-kind.yaml" | yq -N 'select(.apiVersion == "policies.kyverno.io/v1") | .metadata.name' | sort -u)"
for n in $names; do
  base="${n%-team-a}"; base="${base%-pods}"; base="${base/derive-labels/ownership-labels}"            # per-team instances are tested under their base name
  [ -d "$T/$base" ] || { echo "FAIL $n: no tests in platform/policies/tests/$base"; fail=1; }
  [ -f "$ROOT/docs/policies/$base.md" ] || { echo "FAIL $n: no docs/policies/$base.md"; fail=1; }
done
while IFS=$'\t' read -r kind name fp; do
  [ "$fp" = Fail ] || { echo "FAIL $kind/$name: failurePolicy is '$fp', must be Fail (ADR-0012)"; fail=1; }
done < <(cat "$R/cluster.yaml" "$R/team-a-kind.yaml" | yq -N 'select(.apiVersion == "policies.kyverno.io/v1") | [.kind, .metadata.name, .spec.failurePolicy // "unset"] | @tsv')
while IFS= read -r msg; do
  for part in "Why:" "Fix:" "Docs: https://"; do
    case "$msg" in *"$part"*) ;; *) echo "FAIL message lacks '$part': ${msg:0:100}…"; fail=1 ;; esac
  done
  link="$(printf '%s' "$msg" | grep -oE 'docs/policies/[a-z-]+\.md' | head -1)"
  [ -n "$link" ] && [ -f "$ROOT/$link" ] || { echo "FAIL message links a missing page: ${link:-none}"; fail=1; }
done < <(cat "$R/cluster.yaml" "$R/team-a-kind.yaml" | yq -N -o=json -I=0 'select(.kind == "ValidatingPolicy" or .kind == "ImageValidatingPolicy") | .spec.validations[] | (.message // .messageExpression)' | jq -r .)
[ $fail = 0 ] && echo "PASS policy set lint: tests, docs, failurePolicy and message format for: $(echo $names | tr '\n' ' ')"

# kyverno test exits 0 for a directory without a test file, so every directory must have one, and the run must report
# at least one passing case and no failure (D-069).
for d in "$T"/*/; do
  [ "$(basename "$d")" = .rendered ] && continue
  name="$(basename "$d")"
  echo "== kyverno test $name"
  if [ ! -f "$d/kyverno-test.yaml" ]; then echo "FAIL $name: no kyverno-test.yaml (pass and fail cases are required)"; fail=1; continue; fi
  out="$(kyverno test "$d" --remove-color 2>&1)"; rc=$?
  echo "$out" | grep -E '│|Summary|ERROR|Error' | grep -vE '^\s*$'
  summary="$(echo "$out" | grep -E 'Test Summary: [0-9]+ tests passed and [0-9]+ tests failed' | tail -1)"
  # "Test Summary: <p> tests passed and <f> tests failed": p is field 3, f is field 7.
  passed="$(echo "$summary" | awk '{print $3}')"; failed="$(echo "$summary" | awk '{print $7}')"
  if [ $rc -ne 0 ] || [ -z "$summary" ] || [ "${passed:-0}" -eq 0 ] || [ "${failed:-1}" -ne 0 ]; then
    echo "FAIL $name: ${summary:-no test summary} (exit $rc)"; fail=1
  else echo "PASS $name: $passed cases"; fi
  grep -q 'result: fail' "$d/kyverno-test.yaml" || { echo "FAIL $name: no fail case"; fail=1; }
  grep -q 'result: pass' "$d/kyverno-test.yaml" || { echo "FAIL $name: no pass case"; fail=1; }
done
exit $fail
