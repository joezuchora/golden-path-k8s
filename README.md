# golden-path-k8s

A public, production-grade reference Internal Developer Platform (IDP) on AKS. It is organized around one idea from
the AKS Engineering Blog: "tools shouldn't dictate your developer contract; they should fulfill it" (F17). The
versioned [Developer Contract](docs/developer-contract.md) (4 promises) is the spine. Every component below exists to
fulfill one promise, is measured against the CNCF capability domains, and names the AKS-native alternative it was
weighed against.

> **Status: Phase 3 of 6. The platform runs on kind: every Phase 3 journey (J1–J4, O1) and platform check passes there
> (`make e2e-all`); Phase 4 (AKS) is in progress: OpenTofu and the cloud preflight are built and validated locally, with no live
> Azure run yet ([tracker](docs/adr/README.md#phase-4-exit-criteria-tracker-d-087)).** Quickstarts not yet available are marked *Planned*. Every decision, including reversed ones, is in the [Decision Log](docs/adr/README.md) and
> [design evolution](docs/design-evolution.md). What comes next: [roadmap](ROADMAP.md); gotchas already solved:
> [known issues](docs/known-issues.md).

The 4 promises come from the AKS blog (F2, F16). **Cilium, Chainguard and Cosign are this repo's extensions; the blog
doesn't mention them (F1, D-015).**

## Developer Contract Matrix

Each component maps to exactly one promise. "AKS-native trade-off" is the managed option the component was weighed
against, and why it wasn't chosen as the default.

| Promise | Component | Why chosen | AKS-native trade-off | CNCF domain |
|---|---|---|---|---|
| P1 A place to run | AKS Standard control + workload clusters | Crossplane and cloud credentials stay off workload clusters; platform upgrades go first (D-002, [ADR-0001](docs/adr/0001-control-and-workload-cluster-split.md)) | AKS Automatic workload clusters (the blog's default, F17) document only Standard as supporting "Bring your own CNI" (F23), which `cilium_mode = byo` needs; Fleet Manager is the documented scale-out path | Infrastructure services |
| P1 A place to run | kind (local profile) | Each phase is proven at zero cost before AKS (D-016) | Dev AKS clusters cost money and are slower to iterate on | Infrastructure services |
| P1 A place to run | Argo CD placement (cluster Secrets + capability labels) | Each ApplicationSet selects one capability label; the in-cluster target is a declarative Secret (D-023) | Fleet Manager resource placement | Automation for delivering and verifying services |
| P1 A place to run | Tenancy render (`platform/tenancy/teams/<team>.yaml`) | One reviewed file creates the team's namespaces, RBAC and ownership labels (D-017, D-028) | Managed namespaces with quota, network policy and RBAC (F16) | Infrastructure services |
| P1 A place to run | Crossplane v2 (namespaced XRDs + function pipelines, `provider-upjet-azure`) | Declarative, continuously reconciled self-service API that also runs on kind (D-003 → D-024, [ADR-0002](docs/adr/0002-crossplane-v2-external-resources.md)) | ASO alone exposes raw Azure resources; kro is "still pre-1.0" (F17) | APIs for automatically provisioning capabilities |
| P1 A place to run | PostgreSQL compositions (`azure`: Flexible Server; `local`: CloudNativePG) | One XRD API with two backends; "Ready" means the app connects, survives rotation, and cleans up (D-024) | Azure Database for PostgreSQL through ASO, with no abstraction layer | Data services |
| P1 A place to run | Cilium CNI (`managed`: Azure CNI Powered by Cilium; `byo`/kind: OSS Cilium) | Microsoft-supported CNI by default; full Cilium as an opt-in (D-005, [ADR-0003](docs/adr/0003-cilium-ebpf-and-gateway-api.md)) | Managed Cilium allows only label-exclusion changes (F3) | Infrastructure services |
| P1 A place to run | `CiliumNetworkPolicy` default-deny baseline (L3/L4) | The app's network boundary, provable for free on kind and managed AKS (D-021, D-027, D-029) | Managed-namespace network policy (F16) | Security services |
| P1 A place to run | OpenTofu (`infra/`) | Open-source license; HCL stays Terraform-compatible (D-013) | Bicep / AVM | Infrastructure services |
| P2 An identity | Entra Workload ID with one UAMI per app per env (`AppIdentity` XR) | No stored secret; per-app blast radius; provable allow/deny (D-022, [ADR-0008](docs/adr/0008-application-workload-identity.md)) | This *is* the AKS-native path; the platform adds per-app scoping and lifecycle | Identity and secret services |
| P2 An identity | External Secrets Operator + Key Vault (`PushSecret` → `ExternalSecret`) | Brokers connection details across the cluster split (ADR-0002) | Workload identity directly, which is preferred wherever the dependency supports Entra auth (ADR-0008) | Identity and secret services |
| P2 An identity | Reloader | Restarts the app when a brokered credential rotates (ADR-0002) | — | Identity and secret services |
| P2 An identity | Gateway API v1.6.1: Envoy Gateway (`managed`), Cilium Gateway (`byo`, kind) | Retired Ingress-NGINX ruled out (F10); both controllers pass v1.6.1 conformance (F14); the feature set is tested, not assumed (D-006, D-027) | Application routing with the Gateway API (F16) is managed but less portable | Infrastructure services |
| P2 An identity | cert-manager | HTTPS certificate for every listener (ADR-0004) | Application routing (F16) | Identity and secret services |
| P2 An identity | ExternalDNS | DNS records for each `HTTPRoute` host (ADR-0004) | Application routing (F16) | Infrastructure services |
| P2 An identity | Azure Front Door Premium + WAF (opt-in, `enable_edge_waf`) | Managed rules and origin lock behind one flag, with no default cost (D-007, [ADR-0004](docs/adr/0004-edge-security-and-waf.md)) | This is AKS-native; OSS Coraza puts rule tuning on the platform team | Security services |
| P2 An identity | ACNS L7/FQDN policy profile (optional; `managed` only) | L7 and FQDN policy on managed Cilium require ACNS (F3); kept optional so the baseline stays free (D-021) | This is AKS-native; it's free with OSS Cilium on `byo` and kind | Security services |
| P3 A way to see what it's doing | Backstage (Kubernetes plugin, `aks` auth on AKS) | A full runnable portal (D-011); per-user Kubernetes RBAC applies (D-025, [ADR-0006](docs/adr/0006-self-service-diagnostics-and-rbac.md)) | AKS desktop, scoped to a namespace (F17); "You can find what's available" isn't built in (F16) | Web portals for provisioning and observing capabilities |
| P3 A way to see what it's doing | Prometheus | Metrics that can be scoped per namespace through a proxy (D-025) | Managed Prometheus access is per workspace or cluster, not per namespace (F8) | Application observability |
| P3 A way to see what it's doing | Grafana (one org per team) + prom-label-proxy | OSS tenant isolation; Viewer can query any data source in its org (F13, D-025) | Managed Prometheus + Container Insights (F16) lack namespace scoping (F8) | Application observability |
| P3 A way to see what it's doing | Hubble (`byo`/kind; platform-only UI) | Flow visibility; the UI isn't multi-tenant, so tenants see flows through the proxy path (ADR-0006) | ACNS flow observability on `managed` | Application observability |
| P3 A way to see what it's doing | OpenCost | Spend by `team`/`app`/`env` labels (ADR-0007) | AKS cost analysis per namespace (F16) | Application observability |
| P3 A way to see what it's doing | `scripts/idp-diagnose.sh` | Every failure signal in one command, namespace-scoped (ADR-0006) | AKS desktop (F17) | Application observability |
| P3 A way to see what it's doing | Tagging and ownership taxonomy (Kyverno mutate, Crossplane tags, Azure Policy) | One source of truth for cost, ownership and paging (D-010, D-017, D-028, [ADR-0007](docs/adr/0007-tagging-and-ownership-taxonomy.md)) | Azure Policy tag inheritance covers Azure resources only | Application observability |
| P4 A safe way to ship | `reusable-build-sign.yaml` (GitHub Actions) | One pipeline verifies the base, builds, scans, signs and attests every image (D-026, [ADR-0005](docs/adr/0005-chainguard-images-and-cosign-enforcement.md)) | ACR and Defender "don't sign application images for you" (F17) | Automation for building and testing products |
| P4 A safe way to ship | Chainguard base images (`:latest@sha256:`) | Minimal bases, free at `:latest` (F6, D-019) | Any base, scanned by Defender for Containers | Security services |
| P4 A safe way to ship | Cosign keyless + SLSA provenance + SPDX SBOM | Binds signer, caller repo/ref and base digest (D-026, F15) | Notation + Ratify with Azure Policy (F17) | Security services |
| P4 A safe way to ship | Trivy (CI gate) + Trivy Operator | Scans at build time and continuously at runtime (ADR-0005) | ACR with Defender for Containers scanning (F16) | Security services |
| P4 A safe way to ship | Kyverno policy set v1 (admission, mutation, `PolicyReport`s) | One engine for images, labels and the baseline; every message gives what, why, fix and a docs link (D-026) | Deployment Safeguards (F16) | Security services |
| P4 A safe way to ship | GitHub Container Registry (GHCR) | Free for a public repo; one registry for kind, CI and real-registry admission tests (D-031) | ACR + Defender (F16) needs Azure credentials from kind and CI | Artifact storage |
| P4 A safe way to ship | Renovate | Base-digest bumps, each gated by the app's tests (D-019) | — | Automation for building and testing products |
| P4 A safe way to ship | Argo CD (GitOps sync, per-team AppProjects, UI and notifications) | "You ship by merging a pull request" (F16); sync and health are scoped per team (D-025) | Argo CD or Flux extension (F16) | Automation for delivering and verifying services |
| P4 A safe way to ship | git-feedback reporter (render failures → commit status) | A values file that doesn't render starts no sync, so Argo CD notifications can't report it; the reporter posts the chart error to the attempted commit (D-075, F50) | — | Automation for delivering and verifying services |
| P4 A safe way to ship | Gitea (kind e2e Git host only) | The journeys open and merge real PRs and read the commit status Argo CD writes back, with no GitHub credentials (D-043, D-066) | — (on AKS the team's real Git host takes its place) | Automation for delivering and verifying services |
| P4 A safe way to ship | Chainsaw e2e + `kyverno test` fitness checks | Each ADR is proven by a test, not by prose (ADR-0000) | — | Automation for delivering and verifying services |
| P4 A safe way to ship | `golden-service` Helm chart 1.x | The app-facing contract surface (D-014, [ADR-0010](docs/adr/0010-contract-versioning.md)) | AKS Automatic defaults, which aren't portable ("The contract is portable, the defaults aren't.", F17) | Golden path templates and docs |
| P4 A safe way to ship | Backstage software templates (Go, Python, .NET) | Asks only for `app` and `env`; everything else is derived (D-017) | None on AKS (F16) | Golden path templates and docs |

Stated v1 gaps: automated progressive delivery (D-032; the blog's "A bad release doesn't reach everyone" is not built in on
AKS either, F16), aggregated logs and tracing, development environments, and messaging (D-033).

## CNCF capability-domain coverage

All 13 domains from the CNCF Platforms White Paper (F18). *Designed* means it is specified in an ADR and not yet proven by
a fitness check. Detail and gaps: [docs/frameworks/cncf-capability-coverage.md](docs/frameworks/cncf-capability-coverage.md).

| # | Domain | v1 status | Delivered by |
|---|---|---|---|
| 1 | Web portals for provisioning and observing capabilities | Designed | Backstage |
| 2 | APIs for automatically provisioning capabilities | Partial: proven on kind (`local` composition, J4); `azure` validated and render-tested, live in Phase 4 | Crossplane v2 XRDs |
| 3 | Golden path templates and docs | Partial: `golden-service` 1.0.0 proven on kind (J1–J4, network contract); Backstage templates in Phase 5 | `golden-service` chart, Backstage templates, this contract |
| 4 | Automation for building and testing products | Partial: `reusable-build-sign` proven in CI (build-hello signs, attests and passes its own admission check); Renovate in Phase 6 | `reusable-build-sign.yaml`, Renovate |
| 5 | Automation for delivering and verifying services | Partial: Argo CD, placement, Gitea and Chainsaw proven on kind (all suites); no automated progressive delivery (D-032) | Argo CD, Chainsaw |
| 6 | Development environments | **Deferred** (D-033) | — |
| 7 | Application observability | Partial: `idp-diagnose.sh` (J3) and the label taxonomy (J1, J4) proven on kind; metrics, Grafana and OpenCost in Phase 6; no aggregated logs or tracing (D-033) | Prometheus, Grafana, Hubble, OpenCost |
| 8 | Infrastructure services | Partial: kind, tenancy, Cilium and the Gateway proven on kind (placement, O1, network contract); AKS and OpenTofu in Phase 4 | AKS, kind, Cilium, Gateway API, OpenTofu |
| 9 | Data services | Partial (PostgreSQL only): proven on kind with CloudNativePG (J4); Azure Flexible Server in Phase 4 | PostgreSQL compositions |
| 10 | Messaging and event services | **Deferred** (D-033) | — |
| 11 | Identity and secret services | Partial: ESO, Reloader and cert-manager proven on kind (J1, J4); Workload ID and Key Vault in Phase 4 | Workload ID, ESO + Key Vault, cert-manager |
| 12 | Security services | Partial: the Kyverno policy set, Cosign keyless, Chainguard bases and the network baseline proven (`make test-policies`, J1, J2, network contract); WAF and ACNS in Phase 4, Trivy Operator in Phase 6 | Kyverno, Cosign, Chainguard, Trivy, network policy, WAF |
| 13 | Artifact storage | Proven: GHCR (build-hello publishes; kind pulls the signed digest anonymously, F48) | GHCR |

Maturity is assessed honestly (currently Provisional / Initial) against both the CNCF model and Microsoft's capability model:
[docs/frameworks/maturity-self-assessment.md](docs/frameworks/maturity-self-assessment.md).

## Diagrams

### 1. Developer Contract flow

A developer supplies only `app` and `env`. Every failure returns to Git with what failed and the next action. Nobody needs
`cluster-admin`.

```mermaid
flowchart LR
  dev["App team"] -->|"app, env"| tmpl["Backstage template"]
  tmpl --> pr["Git pull request"]
  pr --> ci["reusable-build-sign.yaml<br/>verify base, build, Trivy, sign, attest"]
  ci --> reg[("GHCR<br/>image, signature, SBOM, provenance")]
  pr -->|"merge"| argo["Argo CD sync<br/>team AppProject"]
  argo --> adm{"Kyverno admission<br/>signer + caller + base digest"}
  reg -.->|"verify"| adm
  adm -->|"allow"| roll["Rollout<br/>golden-service chart"]
  roll --> route["HTTPRoute<br/>HTTPS URL"]
  argo --> xr["XR in tenant namespace<br/>control cluster"]
  xr --> cp["Crossplane composition"]
  cp -->|"Ready: app connects"| roll
  adm -->|"deny: what, why, fix, docs link"| fb["PR status, PolicyReport,<br/>Backstage, idp-diagnose"]
  roll -->|"unhealthy"| fb
  cp -->|"stalled: XR conditions"| fb
  fb -->|"fix through Git"| pr
```

### 2. Network traffic path: `managed` vs. `byo` vs. kind

Apps depend only on `HTTPRoute` and `CiliumNetworkPolicy`. The mode changes the `GatewayClass` and the dataplane, not the
app's manifests (D-005, D-027).

```mermaid
flowchart LR
  client["Client"]
  subgraph managed["cilium_mode = managed (AKS default)"]
    afd1["Azure Front Door Premium + WAF<br/>opt-in"] --> eg["Envoy Gateway"]
    eg --> pod1["App pod"]
    pol1["Azure CNI Powered by Cilium<br/>L3/L4 default-deny<br/>L7/FQDN only with ACNS"] -.->|"enforces"| pod1
  end
  subgraph byo["cilium_mode = byo (AKS)"]
    afd2["Azure Front Door Premium + WAF<br/>opt-in"] --> cg2["Cilium Gateway"]
    cg2 --> pod2["App pod"]
    pol2["OSS Cilium, kube-proxy replacement<br/>L3/L4 default-deny, L7/FQDN, Hubble"] -.->|"enforces"| pod2
  end
  subgraph kind["kind (local, every PR)"]
    cg3["Cilium Gateway"] --> pod3["App pod"]
    pol3["OSS Cilium, same values as byo<br/>no Front Door"] -.->|"enforces"| pod3
  end
  client --> afd1
  client -->|"WAF disabled"| eg
  client --> afd2
  client -->|"WAF disabled"| cg2
  client --> cg3
```

With the WAF enabled, Front Door reaches the gateway's internal load balancer through a Private Link origin, and a
direct request to the origin is refused ([ADR-0004](docs/adr/0004-edge-security-and-waf.md)).

### 3. Crossplane external-resource reconciliation, including the ESO secret path

```mermaid
flowchart TB
  subgraph control["Control cluster (kind: the same cluster)"]
    xr["PostgreSQLInstance XR<br/>namespace tenant-{team}-{env}"] --> comp{"Composition<br/>selected by label"}
    comp -->|"provider: azure"| mrs["Namespaced MRs<br/>ResourceGroup, FlexibleServer, Vault"]
    comp -->|"provider: local"| cnpg["CloudNativePG cluster"]
    comp --> csec["Composed connection Secret"]
    csec --> push["ESO PushSecret"]
    idxr["AppIdentity XR"] --> uami["UAMI, federated credential,<br/>role assignment"]
    mrs -->|"observe, diff, correct drift"| mrs
  end
  mrs --> azure[("Azure<br/>per-tenant resource group")]
  uami --> azure
  push --> kv[("Key Vault<br/>kind: Kubernetes SecretStore")]
  subgraph workload["Workload cluster: namespace {team}-{env}"]
    es["ExternalSecret"] --> wsec["Secret"]
    wsec --> app["App pod<br/>golden-service"]
    sa["ServiceAccount<br/>federated to the UAMI"] --> app
    rel["Reloader"] -.->|"restart on rotation"| app
  end
  kv --> es
  app -->|"Entra token on AKS<br/>brokered password on kind"| db[("PostgreSQL")]
  azure --- db
  cnpg --- db
```

Deletion runs in reverse: `deletionPolicy: Delete`, Crossplane `Usage` for ordering, and the per-tenant resource group as
the blast-radius boundary. Kind is the one place the identity promise deviates (brokered password instead of federation;
[ADR-0008](docs/adr/0008-application-workload-identity.md)).

## Quickstarts

### Prerequisites

Start with **[docs/getting-started.md](docs/getting-started.md)** and `make doctor`, which checks every prerequisite (D-056):
a Linux-container engine with at least 8 GiB of memory, cgroup v2 and kernel 5.14 or later, bash 4 or later, GNU make 4 or
later, and outbound HTTPS. `make tools` installs every other CLI at its pinned, checksum-verified version (D-048,
[toolchain](docs/toolchain.md)).

### kind: *Available (Phase 3).* The platform, the policy set and every journey run locally; see [journeys](docs/journeys/README.md).

```bash
make doctor                      # prerequisites (PROFILE=local|docs|github|cloud|all)
make kind-up                     # Docker required; on Windows use WSL2 or Git Bash
make validate                    # static checks
make test-policies               # kyverno test for every policy (needs network: F35)
make e2e JOURNEY=<journey-dir>   # one Chainsaw suite on kind; make e2e-all runs all seven
make kind-down
```

### AKS: *Planned (Phase 4). These commands don't exist yet.*

```bash
tofu -chdir=infra/envs/<env> init
tofu -chdir=infra/envs/<env> plan   # cilium_mode = managed (default) | byo; enable_edge_waf = false (default)
```

AKS support is declared only after the network contract suite passes on `managed` and `byo` (D-027) and the identity
allow/deny gate passes (ADR-0008).

## Docs

- [Developer Contract v1.0](docs/developer-contract.md): the promises, the versioned surface, RACI, escape hatches, failure and recovery, and metrics
- [Decision Log and ADRs](docs/adr/README.md), with phases and exit criteria
- [Design evolution](docs/design-evolution.md)
- [CNCF capability coverage](docs/frameworks/cncf-capability-coverage.md) · [Maturity self-assessment](docs/frameworks/maturity-self-assessment.md)
- Docs check: `bash scripts/verify-docs.sh` (D-035)

## Sources

Each source is cited only for what the Decision Log's verified-facts table records.

| Source | Used for | Verified facts |
|---|---|---|
| [AKS Engineering Blog, "Build the platform, not the plumbing, on AKS" (Paul Yu, 2026-11-09)](https://blog.aks.azure.com/2026/11/09/build-the-platform-not-the-plumbing) | The 4 promises, the promise-to-component tables, the control/workload split, trade-offs | F1, F2, F8, F16, F17 |
| [CNCF Platforms White Paper](https://tag-app-delivery.cncf.io/whitepapers/platforms/) | Platform definition, 7 attributes, 13 capability domains | F18 |
| [CNCF Platform Engineering Maturity Model](https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/) | 5 aspects × 4 levels | F9, F19 |
| [Microsoft Learn: platform engineering capability model](https://learn.microsoft.com/en-us/platform-engineering/platform-engineering-capability-model) | 6 capabilities × 5 stages | F9, F20 |
| [Microsoft Learn: What is platform engineering?](https://learn.microsoft.com/en-us/platform-engineering/what-is-platform-engineering) | Thinnest viable platform, no big bang, golden paths, product mindset | F21 |
| [DORA metrics](https://dora.dev/guides/dora-metrics/) | Delivery metrics in the contract | F22 |

Every other technical fact (Cilium, Crossplane, Argo CD, Kyverno, Fulcio, Grafana, Backstage, Chainguard, Gateway API
conformance) is cited from its own primary source in the Decision Log (F3–F7, F10–F15).
