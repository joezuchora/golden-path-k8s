#!/usr/bin/env bash
# J2: a rejected change tells you how to fix it (exit criterion 4). Two changes are merged by PR and denied at admission;
# each denial reaches Git as a failed commit status carrying what failed, why, the fix and a docs link.
#   (a) image: the same app pushed without the platform signature (UNSIGNED fixture)
#   (b) manifest: a Deployment committed into xrs/dev/, which syncs into the tenant namespace (XRs only)
set -euo pipefail
. ../lib/gitea.sh; . ../lib/app.sh
fail=0
actionable() { # description policy → checks the four parts
  local d=$1 p=$2 part
  for part in "$p:" "Why:" "Fix:" "Docs: https://"; do
    case "$d" in *"$part"*) ;; *) echo "FAIL commit status lacks '$part': ${d:0:300}"; fail=1; return ;; esac
  done
  echo "PASS actionable denial ($p): ${d:0:400}"
}

echo "== (a) unsigned image"
printf 'app: hello\nenv: dev\nimage: %s\nreplicas: 1\n' "$HELLO_UNSIGNED" >/tmp/j2a.$$
sha="$(ship team-a hello dev /tmp/j2a.$$ j2-unsigned)"; rm -f /tmp/j2a.$$
echo "merged team-a/deploy → $sha"
if d="$(wait_status team-a/deploy "$sha" failure team-a-hello-dev 360)"; then actionable "$d" image-admission; else fail=1; fi
if kubectl -n team-a-dev get deploy hello >/dev/null 2>&1; then echo "FAIL the unsigned Deployment exists"; fail=1
else echo "PASS nothing was admitted (no Deployment in team-a-dev)"; fi

echo "== (b) manifest outside the contract"
cat >/tmp/j2b.$$ <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: sideloaded}
spec:
  selector: {matchLabels: {app: sideloaded}}
  template:
    metadata: {labels: {app: sideloaded}}
    spec:
      containers:
        - name: app
          image: $HELLO_SIGNED
          resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {memory: 32Mi}}
EOF
n="$(pr_put_file team-a/deploy j2-sideload xrs/dev/sideloaded.yaml /tmp/j2b.$$ "Add a helper deployment")"; rm -f /tmp/j2b.$$
sha="$(pr_merge team-a/deploy "$n")"; appset_refresh xrs-team-a
kubectl -n argocd annotate application team-a-xrs-dev argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
echo "merged team-a/deploy → $sha"
if d="$(wait_status team-a/deploy "$sha" failure team-a-xrs-dev 360)"; then actionable "$d" tenant-namespace-xrs-only; else fail=1; fi
if kubectl -n tenant-team-a-dev get deploy sideloaded >/dev/null 2>&1; then echo "FAIL the sideloaded Deployment exists"; fail=1
else echo "PASS nothing was admitted (no Deployment in tenant-team-a-dev)"; fi
exit $fail
