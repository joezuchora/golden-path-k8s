#!/usr/bin/env bash
# Cross-tenant deny, Argo CD API (D-025). Identities are per-team local accounts bound to AppProject roles (D-050).
set -euo pipefail
. ../lib/argocd.sh
fail=0
expect() { if [ "$2" = "$3" ]; then echo "PASS $1 → $3"; else echo "FAIL $1 → $3 (expected $2)"; fail=1; fi; }
TA="$(argo_team_token team-a)"
expect "team-a GET project team-a" 200 "$(argo "$TA" GET /projects/team-a | code_of)"
expect "team-a GET project team-b" 403 "$(argo "$TA" GET /projects/team-b | code_of)"
expect "team-a GET project team-c" 403 "$(argo "$TA" GET /projects/team-c | code_of)"
expect "team-a can-i get team-a/*" '{"value":"yes"}' "$(argo "$TA" GET /account/can-i/applications/get/team-a/any | body_of)"
expect "team-a can-i get team-b/*" '{"value":"no"}' "$(argo "$TA" GET /account/can-i/applications/get/team-b/any | body_of)"
expect "team-a can-i sync team-b/*" '{"value":"no"}' "$(argo "$TA" GET /account/can-i/applications/sync/team-b/any | body_of)"
expect "team-a can-i create team-a/*" '{"value":"no"}' "$(argo "$TA" GET /account/can-i/applications/create/team-a/any | body_of)"
expect "team-a can-i get platform/*" '{"value":"no"}' "$(argo "$TA" GET /account/can-i/applications/get/platform/any | body_of)"
# Real requests against applications that must exist: every team has a <team>-xrs-<env> application in its own project
# (D-061). A missing target fails the test; it never turns into a skipped check.
own=team-a-xrs-dev; other=team-b-xrs-dev
for a in $own $other; do
  [ "$(kubectl -n argocd get application "$a" -o jsonpath='{.spec.project}' 2>/dev/null)" = "${a%%-xrs-*}" ]     || { echo "FAIL precondition: application $a doesn't exist in project ${a%%-xrs-*}"; fail=1; }
done
expect "team-a GET own application $own" 200 "$(argo "$TA" GET "/applications/$own" | code_of)"
expect "team-a GET application $other (team-b)" 403 "$(argo "$TA" GET "/applications/$other" | code_of)"
expect "team-a POST sync $other (team-b)" 403 "$(argo "$TA" POST "/applications/$other/sync" '{}' | code_of)"
expect "team-a GET application platform-root" 403 "$(argo "$TA" GET /applications/platform-root | code_of)"
list="$(argo "$TA" GET /applications)"
expect "team-a list applications" 200 "$(echo "$list" | code_of)"
names="$(echo "$list" | body_of | jq -r '[.items[]?.metadata.name] | join(",")')"
projects="$(echo "$list" | body_of | jq -r '[.items[]?.spec.project] | unique | join(",")')"
case ",$names," in *",$own,"*) echo "PASS team-a's list includes its own $own";; *) echo "FAIL team-a's list lacks $own: $names"; fail=1;; esac
case ",$names," in *",$other,"*) echo "FAIL team-a's list shows $other"; fail=1;; *) echo "PASS team-a's list omits $other";; esac
[ "$projects" = team-a ] && echo "PASS every listed application is in project team-a" || { echo "FAIL listed projects: $projects"; fail=1; }
exit $fail
