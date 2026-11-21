#!/usr/bin/env bash
# render-repo-coords.sh: the only supported way to change the repo coordinates (D-046, CLAUDE.md invariant).
# They feed cosign signer and caller identities (admission), Argo CD repoURLs, the GHCR image prefix, policy docs links
# and the Go module path, so a fork must re-render them before its first signed build.
#
#   bash scripts/render-repo-coords.sh <owner>/<name>   rewrite every derived reference and repo-coords.env
#   bash scripts/render-repo-coords.sh --check          fail if any file disagrees with repo-coords.env
#
# History (docs/adr/, docs/design-evolution.md) is never rewritten: it records what was decided at the time.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
. ./repo-coords.env
OLD="$REPO"
SCOPE=(platform charts .github apps scripts infra tests tools docs/policies docs/journeys docs/getting-started.md Makefile)
files() { git ls-files -co --exclude-standard -- "${SCOPE[@]}" | while read -r f; do [ -f "$f" ] && grep -Iq . "$f" && echo "$f"; done; }

if [ "${1:-}" = --check ]; then
  # Any "<x>/golden-path-k8s" coordinate in code must be the current one (owner may be any GitHub login).
  bad="$(files | xargs grep -nHoE '(github\.com|ghcr\.io)/[A-Za-z0-9-]+/golden-path-k8s' 2>/dev/null | grep -v "/$OLD" || true)"
  if [ -n "$bad" ]; then echo "FAIL: references that don't match repo-coords.env ($OLD):"; echo "$bad"; exit 1; fi
  echo "PASS: every repo coordinate matches repo-coords.env ($OLD)"; exit 0
fi

NEW="${1:?usage: $0 <owner>/<name> | --check}"
[[ $NEW =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || { echo "FAIL: '$NEW' is not <owner>/<name>"; exit 2; }
[ "$NEW" = "$OLD" ] && { echo "coordinates already $NEW"; exit 0; }
NEW_OWNER="${NEW%/*}"; NEW_NAME="${NEW#*/}"
n=0
while read -r f; do
  if grep -qF "$OLD" "$f"; then
    OLD="$OLD" NEW="$NEW" perl -pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$f"; n=$((n+1)); echo "  rewrote $f"
  fi
done < <(files)
printf '# Repo coordinates (D-046). Change them only with scripts/render-repo-coords.sh, which rewrites every derived reference.\nREPO_OWNER=%s\nREPO_NAME=%s\nREPO=%s\n' \
  "$NEW_OWNER" "$NEW_NAME" "$NEW" >repo-coords.env
echo "rendered $OLD → $NEW in $n files. Next: make validate && make test-policies, then push and let build-hello sign the first image."
