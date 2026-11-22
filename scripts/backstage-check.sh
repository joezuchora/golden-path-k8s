#!/usr/bin/env bash
# backstage-check.sh: the Backstage app's checks (D-101). Installs from the lockfile, validates the app configuration,
# type-checks, and runs the backend and frontend tests. Needs Node 24.15+ or 26.13+ and Corepack (for Yarn 4.13.0).
# No Git, Azure or Kubernetes credential is needed or read.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../backstage/app"
node -e 'const [maj,min]=process.versions.node.split(".").map(Number); if(!((maj===24&&min>=15)||(maj===26&&min>=13)||maj>26)){console.error(`FAIL: Node ${process.versions.node}; Backstage needs 24.15+ or 26.13+`);process.exit(1)}'
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0 CI=true
yarn() { corepack yarn "$@"; }

echo "== yarn install --immutable"; yarn install --immutable
echo "== app config";              yarn backstage-cli config:check --lax
echo "== tsc";                     yarn tsc
echo "== tests";                   yarn backstage-cli repo test --watch=false
echo "PASS: backstage-check"
