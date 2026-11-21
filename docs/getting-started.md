# Getting started: prerequisites and setup

Everything here is checked by one command, `make doctor` (D-056). If the doctor passes, the commands it gates will run. If a
step here and the doctor disagree, the doctor is right, and this page has a bug.

| You want to | Profile | Status |
|---|---|---|
| Run the platform and the journeys on your laptop (kind) | `make doctor` (`local`) | Phase 3, in progress |
| Run the docs gate (`scripts/verify-docs.sh`) | `make doctor PROFILE=docs` | Available |
| Run the signed-image journeys (J1 allow path) against GHCR | `make doctor PROFILE=github` | Phase 3, M7 |
| Run on AKS (`managed` or `byo`) | `make doctor PROFILE=cloud` | **Phase 4: not available yet** |

## 1. Local (kind)

### Supported hosts

| Host | Shell | Container engine | Status |
|---|---|---|---|
| Windows 11 (amd64) | Git Bash, or a WSL2 distro | Docker Desktop, WSL 2 backend | Tested (Windows 11, WSL kernel 6.18, Docker 29.9, Git Bash 5.3, GNU Make 4.4.1) |
| Linux (amd64, arm64) | bash | Docker Engine | Lock entries present for both; not yet run end to end |
| macOS (Apple Silicon, Intel) | bash ≥ 4 | Docker Desktop | Lock entries present for both; not yet run end to end |

The kind project states that it "is not able to provide support with Windows and WSL" (F37). This repo tests Windows itself,
and the doctor checks exactly what Cilium needs: cgroup v2 and an engine kernel ≥ 5.14 (F30).

### What you install yourself

| Requirement | Why | Checked by |
|---|---|---|
| A container engine running **Linux containers** (Docker Desktop or Docker Engine) | kind runs each node as a container; "`kind` for Windows requires Linux containers" (F37) | `doctor`: engine reachable, Linux containers |
| **Memory available to the engine ≥ 10 GiB** (see [Memory](#memory)) | The full kind platform. The threshold is provisional until the whole Phase 3 stack is measured (M10) | `doctor`: engine memory |
| **cgroup v2** and an engine kernel **≥ 5.14** | Cilium's socket-LB on kind (F30) | `doctor` |
| **bash ≥ 4.0** | The scripts. macOS ships bash 3.2, so put a current bash first on `PATH` | `doctor` |
| **GNU make ≥ 4.0** | The Makefile uses `.SHELLFLAGS`. macOS ships an older make | `doctor` |
| git, curl, tar, unzip, awk, sed, grep, find, sort, mktemp, and `sha256sum` or `shasum` | `tools/install.sh` and the bootstrap | `doctor` |
| Outbound HTTPS to the registries, chart repos, CLI downloads and Sigstore listed by the doctor | Images, charts and signature verification. `make test-policies` is **online**: image policies verify real signatures through Rekor (F35) | `doctor`: network endpoints |

Everything else (kind, kubectl, helm, kyverno, chainsaw, crossplane, tofu, tflint, kubeconform, cosign, jq, yq, cilium,
argocd) is installed by `make tools` into `./.bin` at the pinned versions, with checksums verified ([toolchain](toolchain.md)).
You don't need global installs, and you don't need admin rights for them.

### Memory

| Engine | Where memory is set | Default |
|---|---|---|
| Docker Desktop, WSL 2 backend (Windows) | `%UserProfile%\.wslconfig`, `[wsl2]` section, `memory=`. Docker: "In WSL 2 mode, configure memory, CPU, and swap limits on the WSL 2 utility VM". The file "does not exist by default"; after editing, run `wsl --shutdown` | 50% of total Windows memory (F38) |
| Docker Desktop on macOS (and Linux, Windows Hyper-V) | Settings → Resources → Advanced → Memory limit | 50% of host memory (F38) |
| Docker Engine on Linux | The host's memory | — |

So a 16 GB laptop gets about 8 GB by default, which is below the threshold. Raise the limit or use a larger host.

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
  `default-address-pools` in Docker's `daemon.json` (F37). The kind Gateway pool assumes the kind network is
  `172.18.0.0/16`; the doctor fails if it isn't.
- **Node IPs aren't reachable from the host** on Docker Desktop: "you cannot reach the kind nodes via IP" (F37). The journeys
  therefore test routes from a client pod inside the cluster, never from the host.
- **Proxies and firewalls:** every endpoint the doctor lists must be reachable over HTTPS.

### Windows specifics

- Use Git Bash or a WSL2 shell, never `cmd` or PowerShell, for `make`.
- `python3` may be the Microsoft Store stub. Install Python ≥ 3.8 and disable the "App execution alias" if the doctor says so
  (only `verify-docs` needs Python).
- `.gitattributes` forces LF line endings on scripts, YAML and the Makefile, so `core.autocrlf=true` is safe.

### Run it

```bash
make doctor          # every check above
make kind-up         # preflight → kind cluster → Gateway API CRDs → Cilium → Gitea → Argo CD → GitOps
make validate        # static checks
make test-policies   # kyverno test (online)
make e2e JOURNEY=<dir>   # one suite (tests/e2e/<dir>); make e2e-all runs every suite
make kind-sync       # after a local change: push the working tree to the in-cluster Gitea; Argo CD reconciles it
make kind-down
```

`make kind-up` pushes a snapshot of your working tree (tracked and untracked files, minus ignored ones) to the in-cluster
Gitea, and Argo CD reconciles the platform from there (D-043). Nothing on your machine is committed or pushed anywhere
else.

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

Only the journeys that admit a CI-signed image need this. Everything else on kind runs without GitHub.

| Requirement | Why |
|---|---|
| A **public** repository (this one, or your fork) | Free 4 CPU / 16 GB runners (F28), and the keyless signer and caller identities admission checks (D-046) |
| **Public GHCR packages** `hello` and `hello-unsigned`, set once by the package admin after build-hello first publishes them | GitHub's docs say a new package starts private and inherits the repo's access permissions "but not the visibility" (F43). kind and `kyverno test` pull the images anonymously, so without this step J1 passes preflight and then fails to pull. Set it on each package's page: **Package settings → Danger Zone → Change visibility → Public**. GitHub's page may warn that this can't be undone; read the warning before confirming. `make doctor PROFILE=github` proves an anonymous pull of the exact digests in `tests/e2e/lib/images.env` |
| GitHub Actions enabled, with `packages: write`, `id-token: write` and `attestations: write` granted to the build workflow | Push to GHCR, sign keyless and attest (ADR-0005) |
| Your fork's coordinates rendered with `scripts/render-repo-coords.sh` (arrives in M7) | The admission policy pins the signer and caller to a real repo (D-026, D-046); a fork has different coordinates |

A keyless signature from a laptop carries your personal email identity and is **rejected by design**. Signed images come
only from CI. Keyless signatures and their certificates are recorded in the public Rekor log: "Signing events are recorded in a
tamper-resistant public log" (F39). Check with `make doctor PROFILE=github`.

## 4. Cloud (AKS): Phase 4

Not available yet. `make doctor PROFILE=cloud` fails on purpose until Phase 4 ships `infra/` and its checks. What the design
already commits to:

| Requirement | Source in this repo |
|---|---|
| An Azure subscription, and an identity allowed to create resource groups and **role assignments** (the `AppIdentity` composition creates role assignments for each app, so app teams never do) | ADR-0008, D-022 |
| AKS Standard for the control and workload clusters (`cilium_mode = byo` needs "Bring your own CNI", listed only for Standard) | ADR-0001, F23 |
| OpenTofu at the pinned version (installed by `make tools`) | D-013, [Version pins](adr/README.md#version-pins) |
| Optional, with its own cost: ACNS for the L7/FQDN profile on `managed`; Azure Front Door Premium for the edge WAF | D-021, D-007 |

Costs, quotas, exact Azure roles and the Azure CLI version are verified from Microsoft's documentation in Phase 4 and added
here. They are not estimated now.
