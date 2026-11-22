# Getting started: prerequisites and setup

Run `make doctor` for local kind prerequisites or select the profile for your task (D-056). Problems people have already
hit, and their fixes, are in [known issues](known-issues.md); what comes next is in the [roadmap](../ROADMAP.md). Run the
corresponding commands below to verify that your setup works.

| You want to | Profile | Status |
|---|---|---|
| Run the platform and the journeys on your laptop (kind) | `make doctor` (`local`) | Available (Phase 3) |
| Run the docs gate (`scripts/verify-docs.sh`) | `make doctor PROFILE=docs` | Available |
| Run the journeys that use CI-built images from GHCR | `make doctor PROFILE=github` | Available (Phase 3) |
| Run on AKS (`managed`; `byo` later) | `make doctor PROFILE=cloud` | **Phase 4 in progress:** preflight and Terraform ready; no live run yet |

## 1. Local (kind)

### Supported hosts

| Host | Shell | Container engine | Status |
|---|---|---|---|
| Windows 11 (amd64) | Git Bash, or a WSL2 distro | Docker Desktop, WSL 2 backend | Tested (Windows 11, WSL kernel 6.18, Docker 29.9, Git Bash 5.3, GNU Make 4.4.1) |
| Linux (amd64, arm64) | bash | Docker Engine | amd64 tested on every PR (GitHub's Ubuntu 24.04 runner runs `make kind-up` and every suite); arm64 not yet run end to end |
| macOS (Apple Silicon, Intel) | bash ≥ 4 | Docker Desktop | Lock entries present for both; not yet run end to end |

The kind project states that it "is not able to provide support with Windows and WSL" (F37). This repo tests Windows itself,
and the doctor checks exactly what Cilium needs: cgroup v2 and an engine kernel ≥ 5.14 (F30).

### What you install yourself

| Requirement | Why | Checked by |
|---|---|---|
| A container engine running **Linux containers** (Docker Desktop or Docker Engine) | kind runs each node as a container; "`kind` for Windows requires Linux containers" (F37) | `doctor`: engine reachable, Linux containers |
| **Memory available to the engine ≥ 8 GiB** (see [Memory](#memory)) | The full kind platform: the whole Phase 3 run (every suite) peaked at 5.97 GiB across the three nodes (F49); 8 GiB leaves headroom for the engine itself | `doctor`: engine memory |
| **cgroup v2** and an engine kernel **≥ 5.14** | Cilium's socket-LB on kind (F30) | `doctor` |
| **bash ≥ 4.0** | The scripts. macOS ships bash 3.2, so put a current bash first on `PATH` | `doctor` |
| **GNU make ≥ 4.0** | The Makefile uses `.SHELLFLAGS`. macOS ships an older make | `doctor` |
| git, curl, tar, unzip, awk, sed, grep, find, sort, mktemp, and `sha256sum` or `shasum` | `tools/install.sh` and the bootstrap | `doctor` |
| Outbound HTTPS to the registries, chart repos, CLI downloads and Sigstore listed by the doctor | Images, charts and signature verification. `make test-policies` is **online**: image policies verify real signatures through Rekor (F35) | `doctor`: network endpoints |

Everything else (kind, kubectl, helm, kyverno, chainsaw, crossplane, terraform, tflint, kubeconform, cosign, jq, yq, cilium,
argocd) is installed by `make tools` into `./.bin` at the pinned versions, with checksums verified ([toolchain](toolchain.md)).
You don't need global installs, and you don't need admin rights for them.

### Memory

| Engine | Where memory is set | Default |
|---|---|---|
| Docker Desktop, WSL 2 backend (Windows) | `%UserProfile%\.wslconfig`, `[wsl2]` section, `memory=`. Docker: "In WSL 2 mode, configure memory, CPU, and swap limits on the WSL 2 utility VM". The file "does not exist by default"; after editing, run `wsl --shutdown` | 50% of total Windows memory (F38) |
| Docker Desktop on macOS (and Linux, Windows Hyper-V) | Settings → Resources → Advanced → Memory limit | 50% of host memory (F38) |
| Docker Engine on Linux | The host's memory | — |

So a 16 GB laptop gets about 8 GB by default: just enough. If the doctor reports less than 8 GiB, raise the limit or use a larger host.

### Linux only: inotify limits

kind's known issues list pod failures with "too many open files" and give these values (F37):

```bash
sudo sysctl fs.inotify.max_user_watches=524288
sudo sysctl fs.inotify.max_user_instances=512
# to persist: add both lines (as "name = value") to /etc/sysctl.conf
```

The doctor warns when they're lower.

### Networking pitfalls

- **Subnet clashes.** Docker's default address pools can clash "with existing networks (like VPNs, labs, etc)"; the fix is
  `default-address-pools` in Docker's `daemon.json` (F37). If the `kind` network already exists, the doctor checks that it
  has an IPv4 `/16`. At bootstrap, the platform derives the Gateway address pool from that subnet (D-068).
- **Node IPs aren't reachable from the host** on Docker Desktop: "you cannot reach the kind nodes via IP" (F37). The journeys
  therefore test routes from a client pod inside the cluster, never from the host.
- **Proxies and firewalls:** every endpoint the doctor lists must be reachable over HTTPS.

### Windows specifics

- Use Git Bash or a WSL2 shell, never `cmd` or PowerShell, for `make`.
- `python3` may be the Microsoft Store stub. Install Python ≥ 3.8 and disable the "App execution alias" if the doctor says so
  (only `verify-docs` needs Python).
- `.gitattributes` forces LF line endings on scripts, YAML and the Makefile, so `core.autocrlf=true` is safe.

### Run it

Before running the full suite with `make e2e-all`, complete the [GitHub fixture setup](#3-github-signed-images-j1-allow-path).

```bash
make hooks           # once per clone: keeps the primary checkout on main; work on branches in worktrees (D-089)
make doctor          # every check above
make kind-up         # preflight → kind cluster → Gateway API CRDs → Cilium → Gitea → Argo CD → GitOps
make validate        # static checks
make test-policies   # kyverno test (online)
make e2e JOURNEY=<dir>   # one suite (tests/e2e/<dir>); make e2e-all runs every suite
make kind-sync       # after a local change: push the working tree to the in-cluster Gitea; Argo CD reconciles it
make kind-down
```

`make kind-up` and `make kind-sync` publish your working-tree contents for tracked files to the in-cluster Gitea.
Argo CD reconciles from that snapshot (D-043). To include a new file, add it to Git with `git add`. If you delete a tracked file
locally, the next snapshot includes the deletion (D-066). Nothing on your machine is committed or pushed anywhere else.

**kubeconfig.** The Makefile points every kind target at its own kubeconfig, `.kube/golden-path.yaml`, refreshed from kind
before each run. Changing your global current context (for example by enabling Docker Desktop's own Kubernetes) can't
redirect the suites. To use kubectl against the kind platform yourself: `export KUBECONFIG=$PWD/.kube/golden-path.yaml`.

**After a Docker Desktop restart.** The kind containers restart on their own, but Docker Desktop's port forward to the
API server can fail with `Unable to connect to the server: EOF` while the API server is healthy inside the node.
`docker restart golden-path-control-plane` restores it (measured 2026-11-21).

**Pod DNS on Docker Desktop.** Cilium's eBPF masquerading breaks pod DNS through Docker Desktop's resolver, so kind runs
iptables masquerading (F40, D-057). If you change the Cilium values, check that `kubectl -n kube-system logs -l
k8s-app=kube-dns` shows no `i/o timeout` errors.

## 2. Docs gate

`bash scripts/verify-docs.sh` needs Python ≥ 3.8, curl, and Node.js (`npx` runs a pinned mermaid-cli). Check with
`make doctor PROFILE=docs`. `OFFLINE=1` skips the external-link check, but then the gate reports a SKIP, not a pass.

## 3. GitHub: signed images (J1 allow path)

The ship, rejected-change, unhealthy-rollout, database, network-contract and placement suites use CI-built images (placement
ships a probe app to prove workload-group assignment, D-079). Kind bootstrap and the onboarding suite can run without those
fixtures.

| Requirement | Why |
|---|---|
| A **public** repository (this one, or your fork) | Free 4 CPU / 16 GB runners (F28), and the keyless signer and caller identities admission checks (D-046) |
| **Public GHCR packages** `hello` and `hello-unsigned`, set once by the package admin after build-hello first publishes them | GitHub's docs say a new package starts private and inherits the repo's access permissions "but not the visibility" (F43). kind and `kyverno test` pull the images anonymously, so without this step J1 passes preflight and then fails to pull. Set it on each package's page: **Package settings → Danger Zone → Change visibility → Public**. GitHub's page may warn that this can't be undone; read the warning before confirming. `make doctor PROFILE=github` proves an anonymous pull of the exact digests in `tests/e2e/lib/images.env` |
| GitHub Actions enabled, with `packages: write`, `id-token: write` and `attestations: write` granted to the build workflow | Push to GHCR, sign keyless and attest (ADR-0005) |
| Your fork's coordinates rendered with `bash scripts/render-repo-coords.sh <owner>/<name>` before its first signed build | The admission policy pins the signer and caller to a real repo (D-026, D-046); a fork has different coordinates |

If you're setting up a fork or refreshing its fixtures:

1. Find a successful `build-hello` run for the branch or tag you intend to use. Pushing sample app or build workflow changes triggers that workflow.
2. Download the `images-env` artifact from the run. Check that `HELLO_BUILT_FROM` in the artifact matches the run's commit SHA.
3. Copy the three `HELLO_*` assignments into `tests/e2e/lib/images.env`, keeping the file's comments. Commit fixture updates through a PR (D-069).
4. Run `make doctor PROFILE=github` to check anonymous registry access for both digests, then run `make e2e-all` against the bootstrapped kind cluster.

A keyless signature from a laptop carries your personal email identity and is **rejected by design**. Signed images come
only from CI. Keyless signatures and their certificates are recorded in the public Rekor log: "Signing events are recorded in a
tamper-resistant public log" (F39). Check with `make doctor PROFILE=github`.

## 4. Cloud (AKS): Phase 4

**In progress (D-087): nothing here has run against Azure yet.** Every AKS step goes through `infra/aks/aks.sh` (the
`make aks-preflight` … `make aks-down` targets call it), which enforces a subscription confirmation, timeouts, a teardown owner and a teardown check (D-083).

The reference deployment uses one existing Azure subscription for the platform and every team. Set
`subscription_id` once in the sandbox Terraform configuration and set team ownership and environment metadata in
`platform/tenancy/teams/`. The project creates a resource group per team and environment. For the enterprise design,
see [subscription placement and vending](adr/0013-subscription-placement-and-vending.md), which describes how to
adopt existing landing zones before automating subscription creation.

1. Fill in the environment: copy `infra/envs/sandbox/sandbox.tfvars.example` to `sandbox.auto.tfvars` (gitignored). The
   subscription, region, environment id, teardown owner, expiry date and API server allowlist have no defaults.
2. `az login`, then `make aks-preflight` (= `make doctor PROFILE=cloud`, read-only, D-084). It checks the subscription,
   your roles, the resource providers, the region's AKS version, VM and vCPU quota and PostgreSQL SKU, a budget, leftovers
   from an earlier run, and that the tfvars have no example values.
3. `make aks-plan`, review the plan, then `GP_CONFIRM_SUBSCRIPTION=<subscription id> make aks-up` (billable).
4. `GP_GITHUB_STATUS_TOKEN=<token> make aks-bootstrap`: Argo CD with Workload Identity on the control cluster, the cluster
   Secrets, the root application and the EnvironmentConfig. The token is a fine-grained GitHub token with commit-status
   write on the teams' deploy repos only (D-080); it's read from the environment and never written to disk.
5. `make aks-down` removes everything and runs `make aks-verify-teardown`, which asks Azure (not the state file) whether
   anything tagged with the environment id, any of the run's resource groups or any role assignment of its identities is left.

| Requirement | Source in this repo |
|---|---|
| An identity with Owner, or Contributor plus User Access Administrator (or Role Based Access Control Administrator), on the subscription: Terraform creates role assignments for the platform identities | D-083, D-084 |
| AKS Standard for the control and workload clusters (`cilium_mode = byo` needs "Bring your own CNI", listed only for Standard) | ADR-0001, F23 |
| Terraform, kubelogin and the other CLIs at the pinned versions (installed by `make tools`) | D-088, D-084, [Version pins](adr/README.md#version-pins) |
| Your egress IP in `api_server_authorized_ip_ranges`: the API servers aren't open to the internet | D-083 |
| Optional, with its own cost: ACNS for the L7/FQDN profile on `managed` (`enable_acns`); Azure Front Door Premium for the edge WAF (`enable_edge_waf`, refused until its module exists) | D-021, D-007 |

Costs are read from the Azure pricing pages, and the subscription's budget is checked before the first run; they are not
estimated here.
