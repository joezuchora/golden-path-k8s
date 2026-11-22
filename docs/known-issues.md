# Known issues and gotchas

Problems that cost real debugging time while building this repo. Each one names its symptom, its cause, what the repo
does about it, and its source in the [Decision Log](adr/README.md). If you hit something new, add it here in the same
shape, with a D- or F-entry.

## Local platform (kind, Docker Desktop, Windows)

| Symptom | Cause | What the repo does | Source |
|---|---|---|---|
| CoreDNS logs `read udp …->192.168.65.254:53: i/o timeout`; no chart or image name resolves from pods | Cilium's eBPF masquerading on Docker Desktop: pods can't reach the engine's DNS proxy | kind uses iptables masquerading (`values-kind.yaml`); eBPF host routing is shown on `byo` AKS instead | F40, D-057 |
| `Unable to connect to the server: EOF` after Docker Desktop restarts, while the API server is healthy inside the node | Docker Desktop's port forward to the kind API server doesn't recover | `docker restart golden-path-control-plane` | [getting-started](getting-started.md#run-it) |
| The suites suddenly target a different cluster, or fail with a certificate error | Something changed the global kubeconfig context (for example Docker Desktop's own Kubernetes) | The Makefile uses its own kubeconfig, `.kube/golden-path.yaml`, and Chainsaw runs with `--kube-context kind-golden-path` | D-068 |
| `curl: option --cacert: is badly used here` from `kubectl exec` in Git Bash | Git Bash rewrites `/ca/ca.crt` into a Windows path before `kubectl.exe` sees it | Test helpers set `MSYS_NO_PATHCONV=1` for `kubectl exec` only (local file paths still need the conversion) | D-073 |
| A value read with `jq -r` makes a URL or comparison fail on Windows | The Windows jq build ends lines with CRLF | Scripts that use jq output wrap it in `tr -d '\r'` | D-073 |
| A script edited on Windows fails with odd parse errors | CRLF line endings | `.gitattributes` forces LF on scripts, YAML and the Makefile | D-048 |
| kind fails on a 16 GB laptop | Docker Desktop and WSL default to 50% of host memory | `make doctor` checks for 8 GiB, the measured peak (5.97 GiB) plus headroom | F38, F49, D-074 |
| Gateway LoadBalancer IPs never answer | The kind network isn't the /16 the pool assumes, often because of a VPN subnet clash | `bootstrap.sh` derives the pool from the kind network's real subnet | F37, D-068 |
| A commit lands on the wrong branch, or a pushed branch is missing your commit | Another agent switched branches in the shared primary checkout while you were working | `make hooks`: the primary checkout stays on `main` (a branch switch is reverted, a commit off `main` is refused); each task runs in its own `git worktree` | D-089 |

## GitOps (Argo CD, Gitea)

| Symptom | Cause | What the repo does | Source |
|---|---|---|---|
| Every application's notifications stop at once | Argo CD parses notification templates and triggers as YAML **before** rendering them, so template logic outside a string value, or an unquoted `a ? b : c`, breaks the whole set | `make validate` parses every template and trigger as YAML | F45, D-067 |
| A commit status stays red after the app recovers | Deduplicating on the revision hides a Healthy → Degraded → Healthy recovery | Triggers key on the sync operation and the health transition | D-067 |
| A values file that doesn't render gets no commit status | A render failure starts no sync and records no revision | The git-feedback reporter posts the chart error to the attempted commit | F50, D-075 |
| Deleting a team's last XR never deletes it | Automated sync won't prune an application to zero resources | XR applications set `allowEmpty: true` | F47, D-073 |
| A test reads the wrong commit status | One deploy-repo commit gets statuses from the team's apps and its XRs | Suites wait for the named application's context | D-073 |
| A changed Argo CD setting never reaches the cluster | Argo CD's own values are bootstrap-owned, not reconciled from Git | `make kind-sync` re-applies them | D-073 |
| Each `kind-up` adds another Gitea webhook | Gitea inserts a new hook on every create call | The seed looks hooks up first and removes duplicates | D-066 |
| A local file you didn't mean to share appears in the in-cluster repo | Older bootstrap versions published untracked files | Only files Git tracks are published; `git add` a new file to include it | D-066 |
| `make kind-up` fails after 10 minutes with `Deployment/argocd/argocd-redis not ready ... Available: 0/1` on a fresh CI runner, and a re-run passes | Likely a stalled anonymous image pull: the chart's default Redis image was the platform's only image from ECR Public | Redis is pinned to a Chainguard image by digest. If it recurs, the CI diagnostics step prints the pod's events | D-090 |
| `make kind-up` fails after 15 minutes with `crossplane-config-in-cluster=Synced/Progressing`, and a re-run passes | Crossplane's pod timed out fetching its function packages (`context deadline exceeded` on `https://xpkg.crossplane.io/v2/`) while the node and runner could reach xpkg; cause not proven | Re-run. The functions are digest-pinned, and on failure CI prints `tests/e2e/lib/registry-probe.sh` (package conditions; xpkg and ghcr.io timed from the pod and node networks). Run it locally with `KUBECONFIG=.kube/golden-path.yaml bash tests/e2e/lib/registry-probe.sh` | D-093 |

## Policy and supply chain (Kyverno, cosign, GHCR)

| Symptom | Cause | What the repo does | Source |
|---|---|---|---|
| A Pod-only policy denies Deployments | Kyverno autogenerates pod policies onto controllers by default | Pod-only policies set `autogen.podControllers.controllers: []`; a regression case expects a Deployment to be skipped | D-073 |
| An attestation fails verification while its signature passes | cosign v3 writes a new bundle format by default | CI signs in the legacy format with Rekor and checks every image against the admission policy before any cluster sees it | F41, D-059 |
| `kyverno test` passes on a directory with no test file | The CLI exits 0 when it finds nothing to run | `make test-policies` requires a test file, a pass case, a fail case and a non-zero pass count | D-069 |
| `kyverno test` fails with "failed to load context: no such key: username" | A policy's `matchConditions` reads the requester, and the test supplied none | Every test directory has a `userinfo.yaml` (Argo CD's controller) | D-063 |
| A new GHCR package can't be pulled anonymously | GitHub's docs disagree on whether packages inherit the repo's visibility | `make doctor PROFILE=github` proves an anonymous pull of the exact digests | F43, F48, D-065 |
| `make validate` passes locally and fails on a fresh runner | `helm dependency build` needs registered Helm repos | Validate fetches with `helm dependency update` and fails if a `Chart.lock` changes | D-073 |
| GitHub rejects a workflow file that yq accepts | An unquoted `: ` or comma in a flow mapping | `make validate` fails a workflow that doesn't parse or contains null keys | D-069 |

## Toolchain

| Symptom | Cause | What the repo does | Source |
|---|---|---|---|
| The Crossplane CLI fails its own checksum | The bare binaries don't match their published `.sha256` | Installed from the bundle tarball, whose checksum matches | F34, D-054 |
| A version override doesn't apply to a later `make` target | The override was set for one command only | Export it for the whole trial; see [toolchain](toolchain.md#upgrading-a-pin) | D-068 |
