#!/usr/bin/env bash
# An in-cluster HTTPS client for the journeys. Docker Desktop can't route to kind node IPs (F37), so routes are tested
# from a pod: it resolves app hosts to the platform Gateway's address and trusts the kind platform CA (D-051).
set -euo pipefail
CLIENT_NS=e2e-client
CURL_IMAGE="cgr.dev/chainguard/curl:latest-dev@sha256:370e6d7f10a00b6d350eefb357dbae835339a84b56de61ada6866494ff916f0d"
client_up() {
  kubectl create namespace "$CLIENT_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n cert-manager get secret platform-ca -o jsonpath='{.data.ca\.crt}' | base64 -d >/tmp/platform-ca.$$
  kubectl -n "$CLIENT_NS" create configmap platform-ca --from-file=ca.crt=/tmp/platform-ca.$$ --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  rm -f /tmp/platform-ca.$$
  kubectl -n "$CLIENT_NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: client}
spec:
  containers:
    - name: curl
      image: $CURL_IMAGE
      command: [sleep, infinity]
      volumeMounts: [{name: ca, mountPath: /ca}]
  volumes: [{name: ca, configMap: {name: platform-ca}}]
EOF
  kubectl -n "$CLIENT_NS" wait --for=condition=Ready pod/client --timeout=120s >/dev/null
}
# client_exec <cmd…>: run a command in the client pod with its arguments passed through unchanged (MSYS_NO_PATHCONV: on
# Git Bash, a pod-side path such as /ca/ca.crt would otherwise be rewritten to a Windows path before kubectl sees it).
client_exec() { MSYS_NO_PATHCONV=1 kubectl -n "$CLIENT_NS" exec client -- "$@"; }
gateway_ip() { kubectl -n platform-gateway get gateway platform -o jsonpath='{.status.addresses[0].value}'; }
# in_curl <host> <scheme> <path> [curl args…] → prints "<http code> <body>"
in_curl() {
  local host=$1 scheme=$2 path=$3; shift 3
  local port=443; [ "$scheme" = http ] && port=80
  client_exec curl -s -m 10 --cacert /ca/ca.crt --resolve "$host:$port:$(gateway_ip)" \
    -w '\n%{http_code}' "$@" "$scheme://$host$path"
}
# wait_http <host> <path> <code> [timeout s] → waits until HTTPS returns <code>
wait_http() {
  local host=$1 path=$2 want=$3 t=${4:-180} out
  for _ in $(seq 1 $((t / 5))); do
    out="$(in_curl "$host" https "$path" 2>/dev/null || true)"
    [ "$(echo "$out" | tail -1)" = "$want" ] && { echo "$out" | sed '$d'; return 0; }
    sleep 5
  done
  echo "FAIL: https://$host$path never returned $want (last: $(echo "$out" | tail -1))" >&2; return 1
}
