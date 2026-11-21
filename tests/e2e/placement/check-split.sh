#!/usr/bin/env bash
# Split fixture (D-023, D-079): kind hosts both capabilities, so it can't tell a swapped selector from a correct one. Register a
# second, unreachable cluster that has ONLY hosts-workloads and assert exactly which Applications target it: every
# workloads component and every team's workloads tenancy, and nothing from the control plane. Then prove team-app
# assignment (D-079): while the fixture is in no workload group, no team app targets it; once it joins the "shared" group
# (kind's own group), a probe app gets one Application per cluster, with distinct, cluster-suffixed names. The fixture is
# removed at the end; its Applications are deleted without their finalizers, because the fake cluster can't be reached.
set -euo pipefail
. ../lib/gitea.sh; . ../lib/app.sh   # sourced first: they set their own EXIT trap, which ours replaces below
jq() { command jq "$@" | tr -d '\r'; }   # the Windows jq build ends lines with CRLF
ROOT="$(git rev-parse --show-toplevel)"
FAKE=split-fixture-workloads
SERVER=https://split-fixture-workloads.invalid:6443
PROBE=placement-probe   # a team-a app with no pods and no route: it exists only to be placed
fail=0
cleanup() {
  kubectl -n argocd delete secret "cluster-$FAKE" --ignore-not-found >/dev/null
  for a in $(kubectl -n argocd get applications -o json | jq -r --arg s "$SERVER" '.items[] | select(.spec.destination.server == $s) | .metadata.name'); do
    kubectl -n argocd patch application "$a" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
    kubectl -n argocd delete application "$a" --wait=false >/dev/null 2>&1 || true
  done
  unship team-a "$PROBE" dev || echo "WARN cleanup: unship $PROBE failed"
  kill "$_gitea_pf" 2>/dev/null || true
}
trap cleanup EXIT
fixture() { # <labels json>: (re)register the fixture with these labels and the kind Secret's annotations
  kubectl -n argocd get secret cluster-in-cluster -o json \
    | jq --arg n "$FAKE" --arg s "$SERVER" --argjson l "$1" '.metadata = {name: ("cluster-" + $n), namespace: "argocd",
          labels: ({"argocd.argoproj.io/secret-type": "cluster", "platform.example.org/hosts-workloads": "true"} + $l),
          annotations: .metadata.annotations}
        | .data.name = ($n | @base64) | .data.server = ($s | @base64)' \
    | kubectl apply -f - >/dev/null
  for as in $(kubectl -n argocd get applicationsets -o name); do
    kubectl -n argocd annotate "$as" argocd.argoproj.io/application-set-refresh=true --overwrite >/dev/null
  done
}
on_fixture() { # Applications that target the fixture: component label, or name
  kubectl -n argocd get applications -o json | jq -r --arg s "$SERVER" \
    '[.items[] | select(.spec.destination.server == $s) | .metadata.labels["platform.example.org/component"] // .metadata.name] | sort | .[]'
}

# --- Probe app for team-a/dev, so the assignment checks have an app to place (replicas 0: no pods, no admission work).
printf 'app: %s\nenv: dev\nimage: %s\nreplicas: 0\nroute: {enabled: false}\n' "$PROBE" "$HELLO_SIGNED" >/tmp/split.$$
ship team-a "$PROBE" dev /tmp/split.$$ "placement-probe-$(date +%s)" >/dev/null; rm -f /tmp/split.$$
wait_app "team-a-$PROBE-dev-in-cluster" Synced Healthy 300 || fail=1

# --- 1. Capability placement, fixture in no workload group.
fixture '{}'
want_w="$(cd "$ROOT/platform/components" && ls */workloads.yaml | cut -d/ -f1 | sort)"
want_t="$(cd "$ROOT/platform/tenancy/teams" && ls *.yaml | sed 's/\.yaml$//' | sort)"
got=""
for _ in $(seq 1 36); do
  got="$(on_fixture)"
  [ "$(echo "$got" | grep -c .)" -ge "$(( $(echo "$want_w" | grep -c .) + $(echo "$want_t" | grep -c .) ))" ] && break
  sleep 5
done
for c in $want_w; do
  echo "$got" | grep -qx "$c" && echo "PASS workloads component $c targets the workloads-only cluster" || { echo "FAIL $c not rendered for the workloads-only cluster"; fail=1; }
done
for t in $want_t; do
  echo "$got" | grep -qx "tenancy-$t-workloads" && echo "PASS tenancy-$t-workloads targets the workloads-only cluster" || { echo "FAIL tenancy-$t-workloads missing"; fail=1; }
done
for c in $(cd "$ROOT/platform/components" && ls */control-plane.yaml | cut -d/ -f1); do
  echo "$got" | grep -qx "$c" && { echo "FAIL control-plane component $c was rendered onto a workloads-only cluster"; fail=1; } || echo "PASS control-plane component $c not rendered for it"
done
echo "$got" | grep -q -- '-control-plane$' && { echo "FAIL a control-plane tenancy render targets the workloads-only cluster"; fail=1; } || echo "PASS no control-plane tenancy render targets it"
# Team apps are assigned by group (D-079): a workloads cluster in no group gets none of them.
sleep 15   # one more ApplicationSet pass, so an app that would wrongly target the fixture has had time to appear
apps="$(kubectl -n argocd get applications -l platform.example.org/team -o json | jq -r --arg s "$SERVER" \
  '[.items[] | select(.spec.destination.server == $s and .metadata.labels["platform.example.org/app"] != null) | .metadata.name] | join(" ")')"
[ -z "$apps" ] && echo "PASS no team app targets a workloads cluster outside every group" || { echo "FAIL team apps target an ungrouped cluster: $apps"; fail=1; }

# --- 2. The fixture joins kind's group: the probe gets one Application per cluster, with distinct names.
fixture '{"platform.example.org/workload-group": "shared"}'
want="team-a-$PROBE-dev-$FAKE"
for _ in $(seq 1 24); do kubectl -n argocd get application "$want" >/dev/null 2>&1 && break; sleep 5; done
if kubectl -n argocd get application "$want" >/dev/null 2>&1; then
  echo "PASS the probe has an Application for the second cluster in its group: $want"
  read -r srv team app env cl <<<"$(kubectl -n argocd get application "$want" -o json | jq -r '[.spec.destination.server,
     .metadata.labels["platform.example.org/team"], .metadata.labels["platform.example.org/app"], .metadata.labels["platform.example.org/env"],
     .metadata.labels["platform.example.org/cluster"]] | join(" ")')"
  [ "$srv $team $app $env $cl" = "$SERVER team-a $PROBE dev $FAKE" ] && echo "PASS it targets the fixture and carries team/app/env/cluster labels" \
    || { echo "FAIL $want: server=$srv labels=$team/$app/$env/$cl"; fail=1; }
else echo "FAIL no Application $want after the fixture joined group shared"; fail=1; fi
n="$(kubectl -n argocd get applications -l "platform.example.org/team=team-a,platform.example.org/app=$PROBE,platform.example.org/env=dev" -o name | wc -l | tr -d ' ')"
[ "$n" = 2 ] && echo "PASS two clusters in the group → two Applications for one app and env (no name collision)" || { echo "FAIL $n Applications for $PROBE/dev (want 2)"; fail=1; }
exit $fail
