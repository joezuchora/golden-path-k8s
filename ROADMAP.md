# Roadmap

What comes next, and why. Phases follow the [Decision Log](docs/adr/README.md#phases-and-exit-criteria); each phase is
approved separately and is done only when every exit criterion passes. Gaps the contract states openly are in the
[Developer Contract](docs/developer-contract.md#stated-gaps-in-v1); problems already solved are in
[known issues](docs/known-issues.md).

**Contributions welcome** on the items marked *help wanted*. Each needs a D-entry, an F-entry for any external fact
(fetched from its primary source), and a test that proves it, the same as the rest of the repo.

## Phase 4: AKS

| Item | Why | Source |
|---|---|---|
| Split AKS (control + workload clusters) with Terraform (D-088), `cilium_mode` managed and byo | The network contract must pass unchanged on both modes | ADR-0001, ADR-0003, D-027 |
| App identity: one UAMI per app per env, federated to its ServiceAccount; Postgres with Entra auth | The identity promise kind can't keep | ADR-0008, D-022 |
| The `azure` PostgreSQL composition live, Key Vault as the team's secret store | Proven statically in Phase 3 only | ADR-0002, D-064 |
| Per-app secret scoping | On kind, credentials are scoped to a team and env | D-071 |
| External Secrets on the control plane as well | PushSecret runs there in a split topology | D-060 |
| Explicit per-env workload-cluster assignment and unique Application names | A second workload cluster would collide today | D-072 |
| Kyverno admission HA and a node-drain test | Admission fails closed, so one webhook replica is a delivery outage | [platform review](docs/platform-review.md) |
| Private connectivity, app → database, through private DNS: one approved and one denied path | The `azure` composition disables public access | [platform review](docs/platform-review.md) |
| Hub (Argo CD) rebuild or disconnect/reconnect drill | Git can't repair an unreachable hub | [platform review](docs/platform-review.md) |
| L7/FQDN add-on profile, and eBPF host routing evidence on byo | Not exercised on kind | D-021, D-057 |
| git-feedback reporter against GitHub | Same API calls as Gitea | D-075 |

## Phase 5: Backstage

| Item | Why | Source |
|---|---|---|
| Backstage with per-user Kubernetes access on AKS and its cross-tenant deny test | A backend is exposed only after its deny test passes | D-025 |
| Go, Python and .NET templates that produce a service passing the Phase 3 journeys | Golden paths for languages other than the sample app | Decision Log, phase 5 |
| Onboard a new team end to end without operator helpers (repo access, review, merge, first HTTPS response) | The O1 suite still uses refresh and seeding helpers | [platform review](docs/platform-review.md) |

## Phase 6: CI, supply chain and measurement

| Item | Why | Source |
|---|---|---|
| Real-registry admission cases: disallowed caller and base-digest mismatch | The binding's negative cases with real images | ADR-0005, D-026 |
| Admission latency, cold and warm | Measured, never estimated | ADR-0005 |
| Renovate with the 14-day age gate and the suites as merge gates | Pins should move without breaking evidence | D-039, D-019 |
| `decision-log-check` in CI | The log's integrity as a required check | D-035 |
| Pre-merge render and policy checks in every team deploy repo | Today a bad value is reported after merge | D-075, [contract gaps](docs/developer-contract.md#stated-gaps-in-v1) |
| GitHub organization baseline: who may change the workflow, tags, caller allowlists and branch protection; repo rename and transfer | Admission trusts these | [platform review](docs/platform-review.md) |
| Metrics, Grafana (one org per team) and OpenCost, with the Grafana cross-tenant deny test | Contract P3 | D-025, D-033 |
| DORA and adoption baselines | No targets without a baseline | D-038 |

## Later, or when a trigger fires

| Item | Trigger | Source |
|---|---|---|
| One generic image-admission policy that reads namespace data, instead of per-team instances | Hundreds of teams | D-055 |
| KCL instead of go-templating for compositions *(help wanted: a spike)* | Composition logic grows typed or complex | D-044 |
| Multiple databases per app, with named bindings | A team needs two | D-071 |
| Workload profiles beyond a stateless HTTP service (slow-starting inference, queue jobs, stateful services) | A team asks; each profile states its lifecycle, identity, diagnostics and support | [contract gaps](docs/developer-contract.md#stated-gaps-in-v1) |
| Brownfield adoption: inventory, ownership handoff, Audit before enforcement, observe-only import, restore drill | An existing workload moves onto the platform | [contract gaps](docs/developer-contract.md#stated-gaps-in-v1) |
| Rollback journey: revert to the previous digest through Git, with a retention window for digests and attestations | Before production promotion | [platform review](docs/platform-review.md) |
| Automated progressive delivery (analysis and automatic rollback) | Out of contract v1 | D-032 |
| Development environments; messaging and events | Deferred from v1 | D-033 |
| An end-to-end run of `make kind-up` and the suites on macOS (Apple Silicon and Intel) and on Linux arm64 *(help wanted)* | Windows (Docker Desktop) and Linux amd64 (GitHub's Ubuntu runner, every PR) run it end to end; the lock entries for the other platforms come from published checksums | D-056 |
