#!/usr/bin/env bash
# Network contract v1 (Developer Contract P1/P2, ADR-0003, D-027, D-039): the six route features and the baseline policy
# semantics, using only golden-service values (HTTPRoute + CiliumNetworkPolicy), plus the installed controller versions.
# Runs as team-b with three apps: web (probe enabled, canary 50/50, may call api), api (path prefix, header match, accepts
# web) and other (healthy, reachable through the gateway, accepts nobody). Every deny has a positive control: the same
# target answers on an allowed path, and the denied attempt must fail as a transport timeout (a policy drop), not with a
# DNS, gateway or application error. Kind-specific inputs (hostnames, the platform CA, the pins) live in the PROFILE block.
set -euo pipefail
. ../lib/gitea.sh; . ../lib/app.sh; . ../lib/client.sh
fail=0
ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fail=1; }
cat >/tmp/nc-web.$$ <<EOF
app: web
env: dev
image: $HELLO_SIGNED
replicas: 1
extraEnv: {PROBE: "1"}
route:
  requestHeaders: {set: {X-Request-Tag: from-gateway}}
  responseHeaders: {add: {X-Served-By: golden-service}}
canary: {enabled: true, image: "$HELLO_SIGNED", weight: 50}
network:
  allowToApps: [{app: api, port: 8080}]
EOF
cat >/tmp/nc-api.$$ <<EOF
app: api
env: dev
image: $HELLO_SIGNED
replicas: 1
route:
  pathPrefix: /v1
  headerMatches: [{name: x-team, value: b}]
network:
  allowFromApps: [{app: web, port: 8080}]
EOF
printf 'app: other
env: dev
image: %s
replicas: 1
' "$HELLO_SIGNED" >/tmp/nc-other.$$
ship team-b api dev /tmp/nc-api.$$ nc-api >/dev/null; ship team-b web dev /tmp/nc-web.$$ nc-web >/dev/null
ship team-b other dev /tmp/nc-other.$$ nc-other >/dev/null; rm -f /tmp/nc-*.$$
wait_app team-b-api-dev Synced Healthy 420 || fail=1
wait_app team-b-web-dev Synced Healthy 420 || fail=1
wait_app team-b-other-dev Synced Healthy 420 || fail=1
client_up
# --- PROFILE (kind): hostnames, CA and pins. AKS profiles replace this block in Phase 4. ---
DOMAIN=apps.kind.test; CILIUM_PIN=v1.20.4; GATEWAY_API_PIN=v1.6.3
W=web-team-b-dev.$DOMAIN; A=api-team-b-dev.$DOMAIN; O=other-team-b-dev.$DOMAIN

echo "== route features"
wait_http "$W" / 200 180 >/dev/null && ok "1 HTTPS listener with a cert-manager certificate (verified against the platform CA)" || bad "1 HTTPS"
[ "$(in_curl "$A" https /v1/orders -H 'x-team: b' | tail -1)" = 200 ] && ok "2 host + path prefix /v1 → 200" || bad "2 path prefix"
[ "$(in_curl "$A" https /other -H 'x-team: b' | tail -1)" = 404 ] && ok "2 outside the prefix → 404" || bad "2 outside prefix"
[ "$(in_curl "$A" https /v1/orders | tail -1)" = 404 ] && ok "3 header match: without x-team → 404" || bad "3 header match"
weights="$(kubectl -n team-b-dev get httproute web -o jsonpath='{range .spec.rules[0].backendRefs[*]}{.name}={.weight} {end}')"
[ "$weights" = "web=50 web-canary=50 " ] && ok "4 weighted backends configured: $weights" || bad "4 backend weights are '$weights'"
tracks="$(for i in $(seq 1 30); do in_curl "$W" https / -D - -o /dev/null | grep -i '^x-app-track:' | tr -d '\r' | awk '{print $2}'; done | sort | uniq -c | tr '\n' ' ')"
case "$tracks" in *stable*canary*|*canary*stable*) ok "4 weighted backends split traffic: $tracks" ;; *) bad "4 weighted backends: $tracks" ;; esac
hdrs="$(in_curl "$W" https / -D - -o /dev/null | tr -d '\r')"
echo "$hdrs" | grep -qi '^x-served-by: golden-service' && ok "5 response header modifier (X-Served-By)" || bad "5 response header"
echo "$hdrs" | grep -qi '^x-echo-request-tag: from-gateway' && ok "5 request header modifier (X-Request-Tag reached the app)" || bad "5 request header"
[ "$(in_curl "$W" http / | tail -1)" = 301 ] && ok "6 HTTP → HTTPS redirect (301)" || bad "6 redirect"

echo "== policy semantics"
probe() { in_curl "$W" https "/probe/$1" | sed '$d'; }
dropped() { case "$1" in *"Client.Timeout"*|*"i/o timeout"*|*"deadline exceeded"*) return 0;; *) return 1;; esac; }
# Positive controls first: the targets are healthy and reachable on an allowed path.
[ "$(in_curl "$O" https / | tail -1)" = 200 ] && ok "control: other answers through the gateway" || bad "control: other isn't reachable through the gateway"
case "$(probe 'dns?host=other.team-b-dev.svc.cluster.local')" in "dns ok"*) ok "DNS egress to kube-dns allowed (web resolves other)";; *) bad "DNS egress";; esac
case "$(probe 'dns?host=github.com')" in "dns ok"*) ok "control: web resolves github.com (so a later failure isn't DNS)";; *) bad "control: web can't resolve github.com";; esac
case "$(probe 'http?url=http://api.team-b-dev.svc.cluster.local/')" in "http ok 200"*) ok "L3/L4 allow by label and port: web → api:8080";; *) bad "web → api allow";; esac
# Denials: each must be a policy drop (timeout).
r="$(probe 'http?url=http://other.team-b-dev.svc.cluster.local/')"
dropped "$r" && ok "L3/L4 default deny: web → other (no allow) dropped: ${r:0:80}" || bad "web → other wasn't dropped: $r"
r="$(probe 'http?url=https://github.com/')"
dropped "$r" && ok "default-deny egress: web → internet dropped: ${r:0:80}" || bad "web → internet wasn't dropped: $r"
set +e; client_exec curl -s -m 5 -o /dev/null http://api.team-b-dev.svc.cluster.local/v1; rc=$?; set -e
[ "$rc" = 28 ] && ok "ingress only from the gateway: a pod outside it times out on api directly (curl exit 28), while the gateway path answers"   || bad "direct ingress to api: curl exit $rc (want 28, a timeout)"

echo "== controller versions (D-039: installed patches)"
cv="$(kubectl -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.containers[0].image}')"
case "$cv" in *:$CILIUM_PIN*) ok "Cilium $cv";; *) bad "Cilium image $cv (pin $CILIUM_PIN)";; esac
gv="$(kubectl get crd httproutes.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}')"
[ "$gv" = "$GATEWAY_API_PIN" ] && ok "Gateway API CRDs $gv" || bad "Gateway API CRDs $gv (pin $GATEWAY_API_PIN)"
echo "INFO the L7/FQDN add-on profile (D-021) isn't exercised in Phase 3; it is proven with the byo and managed profiles in Phase 4"
exit $fail
