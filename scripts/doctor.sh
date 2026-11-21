#!/usr/bin/env bash
# doctor.sh: check every prerequisite before you run anything (D-056). docs/getting-started.md explains each check.
#
# Profiles:
#   local   (default) host tools, Docker resources, Linux kernel limits, network endpoints  → needed for kind
#   docs    what scripts/verify-docs.sh needs (python3, curl, npx)
#   github  what the signing and real-registry journeys need (public repo, coordinates)      → needed for J1 allow path
#   cloud   what an AKS run needs (D-084): az login, subscription, permissions, providers, region, AKS version,
#           VM quota, PostgreSQL SKU, budget, leftovers, and the env's tfvars (GP_ENV, default sandbox)
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
  # Cloud preflight (D-084): everything an AKS run needs, checked read-only before anything billable exists. It reads the
  # environment's tfvars (infra/envs/$GP_ENV/$GP_ENV.auto.tfvars) and asks Azure only read questions.
  hdr "Azure / AKS (Phase 4, D-084)"
  jq() { command jq "$@" | tr -d '
'; }   # the Windows jq build ends lines with CRLF
  local envname="${GP_ENV:-sandbox}" envdir="$ROOT/infra/envs/${GP_ENV:-sandbox}"
  local tfvars="$envdir/${GP_ENV:-sandbox}.auto.tfvars"
  az_() { az "$@" --only-show-errors 2>/dev/null | tr -d '\r'; }
  tfv() { # tfv <key>: a string or number value from the tfvars file (first match), without quotes
    sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"?([^\"#]*[^\"#[:space:]])\"?.*$/\1/p" "$tfvars" 2>/dev/null | head -1; }

  # --- Tools
  if has az; then
    local azv; azv="$(az version --query '"azure-cli"' -o tsv 2>/dev/null | tr -d '\r')"
    version_ge "${azv:-0}" 2.60.0 && pass "az CLI $azv" || fail "az CLI ${azv:-unknown}; need >= 2.60 (https://learn.microsoft.com/cli/azure/install-azure-cli)"
  else fail "az CLI not found (https://learn.microsoft.com/cli/azure/install-azure-cli)"; return; fi
  local t; for t in terraform kubelogin kubectl helm; do has "$t" && pass "$t (./.bin)" || fail "$t missing; run make tools"; done

  # --- The environment's inputs
  [ -f "$tfvars" ] || { fail "$tfvars not found: copy $envdir/$envname.tfvars.example and fill it in (confirm every value with the environment owner)"; return; }
  local sub loc id owner expires vm cn wn
  sub="$(tfv subscription_id)"; loc="$(tfv location)"; id="$(tfv environment_id)"; owner="$(tfv teardown_owner)"
  expires="$(tfv expires_on)"; vm="$(tfv vm_size)"; vm="${vm:-Standard_D4as_v5}"
  cn="$(tfv control_node_count)"; cn="${cn:-2}"; wn="$(tfv workload_node_count)"; wn="${wn:-2}"
  local k; for k in subscription_id location environment_id teardown_owner expires_on platform_cost_center api_server_authorized_ip_ranges; do
    grep -qE "^[[:space:]]*$k[[:space:]]*=" "$tfvars" && pass "tfvars sets $k" || fail "tfvars is missing $k (required, no default: D-083)"
  done
  case "$sub$owner" in *00000000-0000-0000-0000-000000000000*|*you@example.com*) fail "tfvars still has the example subscription or owner";; esac
  grep -q '203.0.113.10' "$tfvars" && fail "tfvars still has the example API server IP (203.0.113.10)"
  [ -n "$owner" ] && pass "teardown owner: $owner" || fail "teardown_owner is empty: every AKS job needs an owner (Phase 4 exit criterion)"
  if [ -n "$expires" ]; then
    local today; today="$(date -u +%Y-%m-%d)"
    if [[ "$expires" < "$today" ]]; then fail "expires_on $expires is in the past"
    elif [[ "$expires" > "$(date -u -d '+14 days' +%Y-%m-%d 2>/dev/null || date -u -v+14d +%Y-%m-%d)" ]]; then warn "expires_on $expires is more than 14 days away for a disposable environment"
    else pass "expires_on $expires"; fi
  fi
  local ip; ip="$(curl -s -m 10 https://api.ipify.org || true)"
  if [ -n "$ip" ]; then grep -qE "\"$ip/32\"" "$tfvars" && pass "API server allowlist includes this machine's egress IP $ip/32" \
    || warn "this machine's egress IP $ip/32 isn't in api_server_authorized_ip_ranges: kubectl and aks.sh bootstrap won't reach the API servers"
  else warn "couldn't read this machine's egress IP (api.ipify.org)"; fi

  # --- Network endpoints the run needs
  local u code
  for u in https://management.azure.com https://login.microsoftonline.com https://registry.terraform.io https://releases.hashicorp.com https://api.github.com \
           https://mcr.microsoft.com/v2/ https://packages.aks.azure.com; do
    if code="$(curl -s -o /dev/null -m 15 -w '%{http_code}' "$u")" && [ "$code" != 000 ]; then pass "$u ($code)"
    else fail "$u unreachable (DNS, proxy or firewall?)"; fi
  done

  # --- Login, subscription, permissions
  local acct; acct="$(az_ account show -o json)"
  [ -n "$acct" ] || { fail "az isn't logged in: run az login (then az account set --subscription <id>)"; return; }
  local utype uname; utype="$(echo "$acct" | jq -r .user.type)"; uname="$(echo "$acct" | jq -r .user.name)"
  pass "az logged in as $uname ($utype), tenant $(echo "$acct" | jq -r .tenantId)"
  local sstate; sstate="$(az_ account show --subscription "$sub" --query state -o tsv)"
  [ "$sstate" = Enabled ] && pass "subscription $sub is Enabled ($(az_ account show --subscription "$sub" --query name -o tsv))" \
    || { fail "subscription $sub isn't accessible or isn't Enabled (state: ${sstate:-none})"; return; }
  local oid
  if [ "$utype" = user ]; then oid="$(az_ ad signed-in-user show --query id -o tsv)"
  else oid="$(az_ ad sp show --id "$uname" --query id -o tsv)"; fi
  if [ -n "$oid" ]; then
    local roles; roles="$(az_ role assignment list --assignee "$oid" --scope "/subscriptions/$sub" --include-inherited --include-groups --query '[].roleDefinitionName' -o tsv | sort -u | tr '\n' ',' )"
    info "roles at the subscription: ${roles:-none}"
    case ",$roles" in
      *,Owner,*) pass "Owner on the subscription (creates resources and role assignments)" ;;
      *,Contributor,*)
        case ",$roles" in *",User Access Administrator,"*|*",Role Based Access Control Administrator,"*) pass "Contributor + role-assignment rights on the subscription" ;;
          *) fail "Contributor without User Access Administrator or Role Based Access Control Administrator: Terraform creates role assignments (identities, AKS RBAC)" ;; esac ;;
      *) fail "need Owner, or Contributor + User Access Administrator, on /subscriptions/$sub (have: ${roles:-none})" ;;
    esac
  else warn "couldn't resolve your object ID (Graph access?); permissions not checked"; fi

  # --- Resource providers (the env registers none itself: resource_provider_registrations = "none")
  local p st
  for p in Microsoft.ContainerService Microsoft.DBforPostgreSQL Microsoft.KeyVault Microsoft.ManagedIdentity Microsoft.Network Microsoft.Compute; do
    st="$(az_ provider show --subscription "$sub" -n "$p" --query registrationState -o tsv)"
    [ "$st" = Registered ] && pass "resource provider $p" || fail "resource provider $p is ${st:-unknown}: az provider register --subscription $sub -n $p"
  done

  # --- Region: AKS version, VM size and quota, PostgreSQL SKU
  [ -n "$(az_ account list-locations --query "[?name=='$loc'].name" -o tsv)" ] && pass "region $loc" || { fail "region '$loc' not found"; return; }
  local kv; kv="$(tfv kubernetes_version)"; kv="${kv:-1.37}"
  local vers; vers="$(az_ aks get-versions --subscription "$sub" -l "$loc" -o json)"
  if echo "$vers" | jq -e --arg v "$kv" '.values[]? | select(.version == $v and ((.isPreview // false) | not))' >/dev/null 2>&1; then
    pass "AKS Kubernetes $kv is GA in $loc (patches: $(echo "$vers" | jq -r --arg v "$kv" '.values[] | select(.version == $v) | .patchVersions | keys | join(", ")'))"
  else fail "AKS Kubernetes $kv isn't GA in $loc (available: $(echo "$vers" | jq -r '[.values[]? | .version + (if .isPreview then " (preview)" else "" end)] | join(", ")'))"; fi
  local sku; sku="$(az_ vm list-skus --subscription "$sub" -l "$loc" --size "$vm" --resource-type virtualMachines -o json)"
  local vcpu fam restr
  vcpu="$(echo "$sku" | jq -r --arg s "$vm" '[.[] | select(.name == $s)][0].capabilities[]? | select(.name == "vCPUs") | .value')"
  fam="$(echo "$sku" | jq -r --arg s "$vm" '[.[] | select(.name == $s)][0].family // empty')"
  restr="$(echo "$sku" | jq -r --arg s "$vm" '[.[] | select(.name == $s)][0].restrictions // [] | map(.reasonCode) | join(",")')"
  if [ -z "$vcpu" ]; then fail "VM size $vm isn't offered in $loc"
  elif [ -n "$restr" ]; then fail "VM size $vm is restricted in $loc for this subscription ($restr)"
  else
    local nwl; nwl="$(grep -cE '^[[:space:]]*[a-z][a-z0-9]{1,7}[[:space:]]*=[[:space:]]*\{[[:space:]]*group' "$tfvars" || true)"; [ "${nwl:-0}" -ge 1 ] || nwl=1
    local need=$(( (cn + nwl * wn + 1 + nwl) * vcpu ))   # every node, plus one surge node per cluster for upgrades
    pass "VM size $vm: $vcpu vCPUs, family $fam; this environment needs up to $need vCPUs ($cn + $nwl×$wn nodes + surge)"
    local use; use="$(az_ vm list-usage --subscription "$sub" -l "$loc" -o json)"
    local q; for q in "$fam" cores; do
      read -r cur lim <<<"$(echo "$use" | jq -r --arg n "$q" '[.[] | select(.name.value == $n)][0] | "\(.currentValue // 0) \(.limit // 0)"')"
      if [ "${lim:-0}" -ge $(( ${cur:-0} + need )) ]; then pass "quota $q: $cur used of $lim, $need needed"
      else fail "quota $q: $cur used of $lim; $need more needed (request an increase, or set a smaller vm_size / node counts)"; fi
    done
  fi
  local pg; pg="$(az_ postgres flexible-server list-skus --subscription "$sub" -l "$loc" -o json)"
  if echo "$pg" | grep -q '"Standard_B1ms"'; then pass "PostgreSQL Flexible Server Standard_B1ms offered in $loc"
  else fail "PostgreSQL Flexible Server Standard_B1ms isn't offered in $loc for this subscription (the azure composition uses it)"; fi

  # --- Budget and leftovers
  local nb; nb="$(az_ consumption budget list --subscription "$sub" -o json | jq 'length' 2>/dev/null || echo 0)"
  if [ "${nb:-0}" -ge 1 ]; then pass "subscription has $nb budget(s): $(az_ consumption budget list --subscription "$sub" -o json | jq -r '[.[] | "\(.name) \(.amount) \(.timeGrain)"] | join("; ")')"
  elif [ "${GP_ALLOW_NO_BUDGET:-0}" = 1 ]; then warn "no budget on the subscription (GP_ALLOW_NO_BUDGET=1)"
  else fail "no budget on subscription $sub: create one with an alert before an AKS run, or set GP_ALLOW_NO_BUDGET=1 with the owner's OK"; fi
  if [ -n "$id" ]; then
    local left; left="$(az_ resource list --subscription "$sub" --tag "environment-id=$id" --query 'length(@)' -o tsv)"
    [ "${left:-0}" = 0 ] && pass "no existing resource is tagged environment-id=$id" \
      || warn "$left resource(s) already tagged environment-id=$id: an earlier run wasn't torn down, or the id is in use (bash infra/aks/aks.sh verify-teardown)"
  fi

  # --- The Terraform root parses with these inputs (no backend, no Azure calls)
  if terraform -chdir="$envdir" init -backend=false -input=false -lockfile=readonly >/tmp/doctor-tf.$$ 2>&1 \
     && terraform -chdir="$envdir" validate -no-color >>/tmp/doctor-tf.$$ 2>&1; then pass "terraform init + validate $envdir"
  else fail "terraform validate $envdir:"; tail -5 /tmp/doctor-tf.$$ | sed 's/^/        /'; fi
  rm -f /tmp/doctor-tf.$$
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
