#!/usr/bin/env bash
# idp-diagnose.sh <app> <env> --team <team> [--as <user>]: what failed, at which step, the current state, and the next
# action, for one app, inside the team's own scope (Developer Contract "Failure and recovery", ADR-0006).
#
# Reads only namespaced objects the team's `view` role can see: its app namespace <team>-<env> and its tenant namespace
# tenant-<team>-<env>. It never reads cluster-scoped objects, so it works with a developer's own credentials.
# Optional: ARGOCD_TOKEN (the team's Argo CD token) and ARGOCD_URL add the sync / admission result from Argo CD.
# --as/--as-group impersonate a team identity (kind substitute for Entra, D-050), as the e2e suites do.
#
# Exit code: 0 when every step is healthy, 1 when a step failed (the report names it), 2 on usage errors.
set -uo pipefail
jq() { command jq "$@" | tr -d '\r'; }   # the Windows jq build ends lines with CRLF; strip it so values are safe in URLs
usage() { echo "usage: $0 <app> <env> --team <team> [--as <user>]"; exit 2; }
APP="${1:-}"; ENV="${2:-}"; shift 2 2>/dev/null || usage
TEAM=""; AS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --team) TEAM="$2"; shift 2 ;;
    --as) AS=(--as "$2" --as-group "${TEAM:?--team before --as}"); shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$APP" ] && [ -n "$ENV" ] && [ -n "$TEAM" ] || usage
NS="$TEAM-$ENV"; TNS="tenant-$TEAM-$ENV"; ARGOAPP="$TEAM-$APP-$ENV"
k() { kubectl "${AS[@]}" "$@"; }
failed=""
report() { # step status detail next
  printf '%-12s %-7s %s\n' "$1" "$2" "$3"
  if { [ "$2" = FAIL ] || [ "$2" = UNKNOWN ]; } && [ -z "$failed" ]; then failed="$1 ($2)"; NEXT="$4"; fi
}
echo "idp-diagnose: app=$APP env=$ENV team=$TEAM (namespace $NS)"
echo "STEP         STATUS  CURRENT STATE"

# 1. Sync and admission (Argo CD). A denied manifest never reaches the cluster, so Argo CD is where it shows.
if [ -n "${ARGOCD_TOKEN:-}" ]; then
  app="$(curl -s -H "Authorization: Bearer $ARGOCD_TOKEN" "${ARGOCD_URL:-http://127.0.0.1:18080}/api/v1/applications/$ARGOAPP")"
  phase="$(echo "$app" | jq -r '.status.operationState.phase // "unknown"')"
  msg="$(echo "$app" | jq -r '.status.operationState.message // ""' | tr '\n' ' ' | cut -c1-400)"
  case "$phase" in
    Succeeded|Running) report Sync OK "Argo CD $ARGOAPP: $phase" "" ;;
    Failed|Error) report Sync FAIL "Argo CD $ARGOAPP: $msg" \
      "Fix the manifest or image in your deploy repo PR; the commit status and the message above say what and why." ;;
    *) report Sync INFO "Argo CD $ARGOAPP: ${phase} (no access, or not synced yet)" "" ;;
  esac
else
  echo "Sync         SKIP    set ARGOCD_TOKEN to include the Argo CD sync and admission result"
fi

# get <out-var> <kubectl args…>: reads one object. Returns 0 (found), 1 (NotFound) or 2 (any other error, e.g. Forbidden
# or the API being unreachable), so "absent" is never confused with "couldn't look".
GET_ERR=""
get() {
  local __v=$1; shift
  local out
  if out="$(k get "$@" -o json 2>&1)"; then printf -v "$__v" '%s' "$out"; return 0; fi
  GET_ERR="$(echo "$out" | head -1 | cut -c1-200)"
  case "$out" in *NotFound*|*"not found"*) return 1 ;; *) return 2 ;; esac
}

# 2. Rollout: healthy only when the controller has seen the current spec and every replica is updated, available and
# ready, with no old replicas left (a ready old ReplicaSet doesn't count).
get dep -n "$NS" deployment "$APP"; rc=$?
if [ $rc = 1 ]; then
  report Rollout FAIL "deployment $NS/$APP not found" \
    "Check the Argo CD sync result and your PR's commit status: the manifest was probably rejected at admission."
elif [ $rc = 2 ]; then
  report Rollout UNKNOWN "couldn't read deployment $NS/$APP: $GET_ERR" "Check your access to $NS (kubectl auth can-i get deployments -n $NS); if it's correct, page the platform on-call."
else
  read -r want gen obs total updated avail ready <<<"$(echo "$dep" | jq -r '[.spec.replicas, .metadata.generation, (.status.observedGeneration // 0),
      (.status.replicas // 0), (.status.updatedReplicas // 0), (.status.availableReplicas // 0), (.status.readyReplicas // 0)] | map(tostring) | join(" ")')"
  prog="$(echo "$dep" | jq -r '[.status.conditions[]? | select(.type=="Progressing")][0] | "\(.reason): \(.message)"')"
  if [ "$obs" -ge "$gen" ] && [ "$updated" = "$want" ] && [ "$avail" = "$want" ] && [ "$ready" = "$want" ] && [ "$total" = "$want" ]; then
    report Rollout OK "$ready/$want ready, all on the current revision" ""
  else
    ev="$(k -n "$NS" get events --field-selector type=Warning -o json 2>/dev/null \
      | jq -r --arg a "$APP" '[.items[] | select(.involvedObject.name | startswith($a))] | sort_by(.lastTimestamp) | reverse
          | map("\(.reason): \(.message)") | unique | .[0:3] | join(" | ")' | cut -c1-400)"
    pods="$(k -n "$NS" get pods -l "platform.example.org/app=$APP" -o json 2>/dev/null \
      | jq -r '[.items[] | .status.containerStatuses[]? | select(.ready|not) | (.state.waiting.reason // "NotReady")] | unique | join(",")')"
    report Rollout FAIL "updated $updated/$want, available $avail/$want, ready $ready/$want, total $total; pods: ${pods:-none}; $prog; events: ${ev:-none}" \
      "Revert the PR, or fix and re-merge (for example the port, probe path or configuration in apps/$APP/$ENV.yaml). Logs: kubectl logs -n $NS -l platform.example.org/app=$APP"
  fi
fi

# 3. Dependencies: the XR in the tenant namespace and the ExternalSecret that delivers its credentials.
if esl="$(k -n "$NS" get externalsecrets -l "platform.example.org/app=$APP" -o name 2>&1)"; then
  for es in $esl; do
    dep="$(k -n "$NS" get "$es" -o jsonpath='{.metadata.labels.platform\.example\.org/dependency}')"
    get xr -n "$TNS" postgresqlinstances "$dep"; rc=$?
    if [ $rc = 1 ]; then
      report Dependency FAIL "XR $TNS/$dep not found" "Add xrs/$ENV/$dep.yaml to your deploy repo by PR, or remove the dependency from your values."
      continue
    elif [ $rc = 2 ]; then
      report Dependency UNKNOWN "couldn't read XR $TNS/$dep: $GET_ERR" "Check your access to $TNS; if it's correct, page the platform on-call."
      continue
    fi
    xready="$(echo "$xr" | jq -r '[.status.conditions[]? | select(.type=="Ready")][0].status // "Unknown"')"
    xmsg="$(echo "$xr" | jq -r '[.status.conditions[]? | select(.status!="True")] | map("\(.type): \(.message // .reason)") | join("; ")' | cut -c1-300)"
    if [ "$xready" != True ]; then
      report Dependency FAIL "XR $TNS/$dep Ready=$xready ${xmsg}" "Fix the XR parameters in Git; if they're valid, it's a provider fault: page the platform on-call."
      continue
    fi
    esr="$(k -n "$NS" get "$es" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    esm="$(k -n "$NS" get "$es" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}')"
    if [ "$esr" = True ]; then report Dependency OK "XR $dep Ready; $es synced" ""
    else report Dependency FAIL "XR $dep Ready but $es not synced: ${esm:-no status yet}" "The XR is fine, so this is a platform fault (ESO / secret store): page the platform on-call."; fi
  done
else
  report Dependency UNKNOWN "couldn't list ExternalSecrets in $NS: $(echo "$esl" | head -1 | cut -c1-200)" "Check your access to $NS; if it's correct, page the platform on-call."
fi

# 4. Route: OK only when the gateway has reported Accepted and ResolvedRefs for the route; no status yet is UNKNOWN.
get rt -n "$NS" httproute "$APP"; rc=$?
if [ $rc = 0 ]; then
  host="$(echo "$rt" | jq -r '.spec.hostnames[0] // "(no hostname)"')"
  acc="$(echo "$rt" | jq -r '[.status.parents[]?.conditions[]? | select(.type=="Accepted")][0].status // "none"')"
  res="$(echo "$rt" | jq -r '[.status.parents[]?.conditions[]? | select(.type=="ResolvedRefs")][0].status // "none"')"
  bad="$(echo "$rt" | jq -r '[.status.parents[]?.conditions[]? | select(.status!="True") | "\(.type)=\(.status) \(.reason): \(.message)"] | join("; ")' | cut -c1-300)"
  if [ "$acc" = True ] && [ "$res" = True ]; then report Route OK "https://$host accepted by the platform gateway, backends resolved" ""
  elif [ "$acc" = none ]; then report Route UNKNOWN "https://$host: the gateway hasn't reported a status yet" "Wait a minute; if it stays without status, page the platform on-call (gateway controller)."
  else report Route FAIL "https://$host: ${bad:-Accepted=$acc ResolvedRefs=$res}" "Check route values (host, path) in apps/$APP/$ENV.yaml; if they're valid, page the platform on-call."; fi
elif [ $rc = 2 ]; then
  report Route UNKNOWN "couldn't read HTTPRoute $NS/$APP: $GET_ERR" "Check your access to $NS; if it's correct, page the platform on-call."
fi

echo
if [ -n "$failed" ]; then echo "FAILED STEP: $failed"; echo "NEXT ACTION: $NEXT"; exit 1; fi
echo "All steps healthy."
