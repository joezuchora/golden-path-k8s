#!/usr/bin/env bash
set -euo pipefail
. ../lib/gitea.sh; . ../lib/app.sh
unship team-a hello dev
echo "removed team-a hello dev"
