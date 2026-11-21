#!/usr/bin/env bash
# For every platform/components/<c>/{control-plane,workloads}.yaml there must be exactly one Argo CD Application with
# label platform.example.org/component=<c>, and it must reach Synced + Healthy. Every ApplicationSet's cluster
# generator must select on exactly one capability label (plus the workload group for team apps) and never on a name (D-023, D-079).
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
# Each cluster generator selects on exactly one capability label; the only other key allowed is the workload group, next to
# hosts-workloads (team apps, D-079). Never a name or a server.
for as in $(kubectl -n argocd get applicationsets -o name); do
  bad="$(kubectl -n argocd get "$as" -o json | jq -r '[.. | objects | select(has("clusters")) | .clusters.selector] | .[]
    | (.matchLabels // {} | keys) as $k
    | if ((.matchExpressions // []) | map(select(.key == "name" or .key == "server")) | length) > 0 then "selects on a cluster name"
      elif ($k | map(select(startswith("platform.example.org/hosts-"))) | length) != 1 then "selects on \($k) (need exactly one capability label)"
      elif ($k - ["platform.example.org/hosts-control-plane", "platform.example.org/hosts-workloads", "platform.example.org/workload-group"] | length) > 0 then "selects on \($k)"
      elif ($k | index("platform.example.org/workload-group")) != null and ($k | index("platform.example.org/hosts-workloads")) == null then "workload-group without hosts-workloads"
      else empty end')"
  keys="$(kubectl -n argocd get "$as" -o json | jq -r '[.. | objects | select(has("clusters")) | .clusters.selector.matchLabels // {} | keys[]] | unique | join(",")')"
  [ -z "$bad" ] && echo "PASS $as selects on $keys" || { echo "FAIL $as: $bad"; fail=1; }
done
exit $fail
