#!/usr/bin/env bash
# For every platform/components/<c>/{control-plane,workloads}.yaml there must be exactly one Argo CD Application with
# label platform.example.org/component=<c>, and it must reach Synced + Healthy. Every ApplicationSet's cluster
# generator must select on exactly one capability label and never on a name (D-023).
set -euo pipefail
jq() { command jq "$@" | tr -d '\r'; }   # the Windows jq build ends lines with CRLF; strip it so values are safe in URLs
ROOT="$(git rev-parse --show-toplevel)"
fail=0
mapfile -t comps < <(cd "$ROOT/platform/components" && ls -d */ | tr -d / | while read -r c; do
  [ -f "$c/control-plane.yaml" ] || [ -f "$c/workloads.yaml" ] && echo "$c"; done)
echo "components with a capability: ${comps[*]}"
deadline=$((SECONDS + 540))
for c in "${comps[@]}"; do
  while :; do
    n="$(kubectl -n argocd get applications -l "platform.example.org/component=$c" -o name | wc -l | tr -d ' ')"
    st="$(kubectl -n argocd get applications -l "platform.example.org/component=$c" -o jsonpath='{range .items[*]}{.status.sync.status}/{.status.health.status}{end}')"
    if [ "$n" = 1 ] && [ "$st" = "Synced/Healthy" ]; then echo "PASS $c: 1 Application, $st"; break; fi
    if [ "$n" -gt 1 ]; then echo "FAIL $c: rendered $n times"; fail=1; break; fi
    if [ $SECONDS -ge $deadline ]; then echo "FAIL $c: count=$n status=${st:-none}"; fail=1; break; fi
    sleep 5
  done
done
for as in $(kubectl -n argocd get applicationsets -o name); do
  sel="$(kubectl -n argocd get "$as" -o json | jq -c '[.. | objects | select(has("clusters")) | .clusters]')"
  keys="$(echo "$sel" | jq -r '[.[] | .selector.matchLabels // {} | keys[]] | unique | join(",")')"
  names="$(echo "$sel" | jq -r '[.[] | .selector.matchExpressions // [] | .[] | select(.key=="name" or .key=="server")] | length')"
  case "$keys" in
    platform.example.org/hosts-control-plane|platform.example.org/hosts-workloads) [ "$names" = 0 ] && echo "PASS $as selects on $keys" || { echo "FAIL $as selects on a cluster name"; fail=1; } ;;
    *) echo "FAIL $as cluster selector is '$keys' (must be exactly one capability label)"; fail=1 ;;
  esac
done
exit $fail
