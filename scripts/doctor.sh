#!/usr/bin/env bash
# doctor.sh: check every prerequisite before you run anything (D-056). docs/getting-started.md explains each check.
#
# Profiles:
#   local   (default) host tools, Docker resources, Linux kernel limits, network endpoints  → needed for kind
#   docs    what scripts/verify-docs.sh needs (python3, curl, npx)
#   github  what the signing and real-registry journeys need (public repo, coordinates)      → needed for J1 allow path
#   cloud   what AKS needs (Phase 4)
#
# Usage: bash scripts/doctor.sh [local|docs|github|cloud|all]
# Exit code: 0 if every FAIL-level check passes. WARN lines don't fail the run but name a likely problem.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$ROOT/.bin:$PATH"
MIN_MEM_GIB="${MIN_MEM_GIB:-8}"   # measured peak 5.97 GiB for the whole Phase 3 run, plus headroom (F49)
fails=0; warns=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; fails=$((fails+1)); }
warn() { printf 'WARN  %s\n' "$*"; warns=$((warns+1)); }
info() { printf 'INFO  %s\n' "$*"; }
hdr()  { printf '\n== %s\n' "$*"; }
has()  { command -v "$1" >/dev/null 2>&1; }

# version_ge <have> <need>: dotted-number comparison
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

os_name() {
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo windows-gitbash ;; Linux) grep -qi microsoft /proc/version 2>/dev/null && echo wsl || echo linux ;; Darwin) echo macos ;; *) uname -s ;; esac
}

check_host() {
  hdr "Host"
  local os; os="$(os_name)"; info "platform: $os ($(uname -m))"
  case "$(uname -m)" in x86_64|amd64|arm64|aarch64) pass "architecture $(uname -m)";; *) fail "architecture $(uname -m) is not supported (amd64 or arm64)";; esac
  [ "$os" = windows-gitbash ] && [ "$(uname -m)" != x86_64 ] && fail "Windows on arm64 is not supported; use WSL2 or an amd64 host"

  local bv="${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"
  version_ge "$bv" 4.0 && pass "bash $bv" || fail "bash $bv; need >= 4.0 (macOS ships 3.2: install a current bash and put it first on PATH)"

  if has make; then
    local mv; mv="$(make --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
    version_ge "${mv:-0}" 4.0 && pass "GNU make $mv" || fail "make ${mv:-unknown}; need GNU make >= 4.0 (the Makefile uses .SHELLFLAGS)"
  else fail "make not found; install GNU make >= 4.0"; fi

  local t
  for t in git curl tar unzip awk sed grep find mktemp sort; do has "$t" && pass "$t" || fail "$t not found"; done
  if has sha256sum || has shasum; then pass "sha256sum/shasum"; else fail "sha256sum or shasum not found"; fi

  # Worktree rule (D-089): several agents share one clone, so the primary checkout stays on main.
  if [ "$(git -C "$ROOT" config --get core.hooksPath 2>/dev/null)" = .githooks ]; then pass "Git hooks enabled (worktree rule, D-089)"
  else warn "Git hooks not enabled: run 'make hooks' (keeps the primary checkout on main; branches go in worktrees, D-089)"; fi

  if [ "$os" = windows-gitbash ] || [ "$os" = wsl ]; then
    if git config --get core.autocrlf >/dev/null 2>&1; then info "git core.autocrlf=$(git config --get core.autocrlf); .gitattributes forces LF for scripts"; fi
  fi
}

check_tools() {
  hdr "Pinned CLIs (./.bin)"
  if bash "$ROOT/tools/install.sh" >/tmp/doctor-tools.$$ 2>&1; then
    pass "all pinned CLIs installed and checksum-verified ($(grep -c '^OK' /tmp/doctor-tools.$$) tools)"
  else
    fail "make tools failed:"; sed 's/^/        /' /tmp/doctor-tools.$$ | tail -5
  fi
  rm -f /tmp/doctor-tools.$$
}

check_docker() {
  hdr "Container engine"
  has docker || { fail "docker CLI not found (Docker Desktop on macOS/Windows, Docker Engine on Linux)"; return; }
  if ! docker info >/dev/null 2>&1; then fail "Docker engine not reachable: start Docker Desktop / the docker service, and check you may use it without sudo"; return; fi
  local mem cg ncpu os gib
  mem="$(docker info --format '{{.MemTotal}}')"; cg="$(docker info --format '{{.CgroupVersion}}')"; ncpu="$(docker info --format '{{.NCPU}}')"
  os="$(docker info --format '{{.OSType}}')"
  gib="$(awk -v m="$mem" 'BEGIN{printf "%.1f", m/1073741824}')"
  [ "$os" = linux ] && pass "Linux containers" || fail "engine runs $os containers; kind needs Linux containers"
  if awk -v g="$gib" -v min="$MIN_MEM_GIB" 'BEGIN{exit !(g+0 >= min+0)}'; then pass "engine memory ${gib} GiB (>= ${MIN_MEM_GIB})"
  else fail "engine memory ${gib} GiB < ${MIN_MEM_GIB} GiB. Docker Desktop (Mac, Hyper-V) defaults to 50% of host RAM; WSL2 defaults to 50% of Windows RAM (F38). See docs/getting-started.md#memory"; fi
  info "engine CPUs: $ncpu"
  [ "$cg" = 2 ] && pass "cgroup v2" || fail "cgroup v$cg; Cilium's socket-LB on kind needs cgroup v2 (F30)"
  local kv; kv="$(docker info --format '{{.KernelVersion}}' | grep -oE '^[0-9]+\.[0-9]+')"
  version_ge "${kv:-0}" 5.14 && pass "engine kernel $kv (>= 5.14, F30)" || fail "engine kernel $kv < 5.14 (F30)"
  local sub; sub="$(docker network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null || true)"
  if [ -n "$sub" ]; then
    echo "$sub" | grep -qE '(^| )[0-9.]+/16( |$)' && pass "kind network $sub (bootstrap derives the Gateway pool from it)" \
      || fail "kind network is '$sub'; the Gateway pool needs an IPv4 /16 (see getting-started: subnet clashes)"
  else info "kind network not created yet (kind creates it; it must not clash with a VPN subnet, F37)"; fi
}

check_linux_limits() {
  [ "$(uname -s)" = Linux ] || return 0
  hdr "Linux kernel limits (kind known issue, F37)"
  local w i
  w="$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)"; i="$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo 0)"
  [ "$w" -ge 524288 ] && pass "fs.inotify.max_user_watches=$w" || warn "fs.inotify.max_user_watches=$w (< 524288): pods may fail with 'too many open files'"
  [ "$i" -ge 512 ] && pass "fs.inotify.max_user_instances=$i" || warn "fs.inotify.max_user_instances=$i (< 512): pods may fail with 'too many open files'"
}

check_network() {
  hdr "Network endpoints (images, charts, CLIs, Sigstore)"
  local u code
  for u in https://github.com https://objects.githubusercontent.com https://dl.k8s.io https://get.helm.sh https://cli.crossplane.io \
           https://registry-1.docker.io/v2/ https://quay.io/v2/ https://ghcr.io/v2/ https://cgr.dev/v2/ https://registry.k8s.io/v2/ \
           https://xpkg.crossplane.io/v2/ https://xpkg.upbound.io/v2/ https://rekor.sigstore.dev https://tuf-repo-cdn.sigstore.dev \
           https://charts.jetstack.io https://argoproj.github.io https://dl.gitea.com https://cloudnative-pg.io https://external-secrets.io \
           https://stakater.github.io https://kyverno.github.io; do
    if code="$(curl -s -o /dev/null -m 15 -w '%{http_code}' "$u")" && [ "$code" != 000 ]; then pass "$u ($code)"
    else fail "$u unreachable (DNS, proxy or firewall?)"; fi
  done
}

check_docs() {
  hdr "Docs gate (scripts/verify-docs.sh)"
  local py=""
  for c in python3 python; do if has "$c" && "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3,8) else 1)' >/dev/null 2>&1; then py="$c"; break; fi; done
  [ -n "$py" ] && pass "$py $("$py" -c 'import platform;print(platform.python_version())')" \
    || fail "python >= 3.8 not found (on Windows, 'python3' may be the Microsoft Store stub; install Python and disable the app alias)"
  has npx && pass "npx (renders Mermaid with a pinned mermaid-cli)" || fail "npx not found (install Node.js LTS); without it the Mermaid check is UNVERIFIED"
}

check_github() {
  hdr "GitHub (signing and real-registry journeys, D-046, D-047)"
  local coords="$ROOT/repo-coords.env"
  if [ -f "$coords" ]; then pass "repo-coords.env: $(grep -E '^REPO=' "$coords" | cut -d= -f2)"; else fail "repo-coords.env missing (arrives with scripts/render-repo-coords.sh, Phase 3 M7)"; fi
  local origin; origin="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"; info "git origin: ${origin:-none}"
  if has gh && gh auth status >/dev/null 2>&1; then
    local repo vis; repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
    vis="$(gh repo view --json visibility --jq .visibility 2>/dev/null || true)"
    [ "$vis" = PUBLIC ] && pass "$repo is public (free 16 GB runners, F28)" \
      || fail "$repo is ${vis:-unknown}; the repo (or your fork) must be public (D-046)"
  else warn "gh not installed or not logged in; can't check repo visibility (optional: GitHub CLI)"; fi
  # A public repo doesn't make its packages public (F43): prove an anonymous pull of the exact digests the journeys use.
  local envf="$ROOT/tests/e2e/lib/images.env" name ref
  for name in HELLO_SIGNED HELLO_UNSIGNED; do
    ref="$(sed -n "s/^$name=//p" "$envf" 2>/dev/null)"
    case "$ref" in
      ghcr.io/*@sha256:*)
        local repo_path="${ref#ghcr.io/}"; repo_path="${repo_path%@*}"; local digest="${ref#*@}" tok code
        tok="$(curl -s "https://ghcr.io/token?scope=repository:$repo_path:pull" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
        code="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $tok" \
          -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
          "https://ghcr.io/v2/$repo_path/manifests/$digest" || true)"
        [ "$code" = 200 ] && pass "$name pulls anonymously from GHCR ($ref)" \
          || fail "$name ($ref) can't be pulled anonymously (HTTP $code). New GHCR packages start private (F43): set the package to public in its Package settings (docs/getting-started.md#3-github-signed-images-j1-allow-path)" ;;
      *) fail "$name in tests/e2e/lib/images.env is '${ref:-unset}': no CI-built image yet (build-hello publishes it, D-059)" ;;
    esac
  done
}

check_cloud() {
  hdr "Azure / AKS (Phase 4)"
  fail "the AKS profile isn't built yet (Phase 4). Its checks (az CLI login, subscription, permissions, quotas, OpenTofu backend) land with infra/envs/"
}

profile="${1:-local}"
case "$profile" in
  local)  check_host; check_tools; check_docker; check_linux_limits; check_network ;;
  docs)   check_docs ;;
  github) check_github ;;
  cloud)  check_cloud ;;
  all)    check_host; check_tools; check_docker; check_linux_limits; check_network; check_docs; check_github; check_cloud ;;
  *) echo "usage: $0 [local|docs|github|cloud|all]"; exit 2 ;;
esac
printf '\ndoctor (%s): %d failed, %d warnings\n' "$profile" "$fails" "$warns"
[ "$fails" -eq 0 ]
