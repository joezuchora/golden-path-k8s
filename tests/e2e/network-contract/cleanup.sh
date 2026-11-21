#!/usr/bin/env bash
set -euo pipefail
. ../lib/gitea.sh; . ../lib/app.sh
unship team-b web dev
unship team-b api dev
unship team-b other dev
echo "network-contract apps removed"
