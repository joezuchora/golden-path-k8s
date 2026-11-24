# Developer Contract v1.0

| | |
|---|---|
| **Version** | 1.0 |
| **Date** | 2026-11-20 |
| **Status** | Specification. Enforcement starts in Phase 3 (kind) and Phase 4 (AKS); each guarantee below names the fitness check that proves it. Until that check passes, the guarantee is *designed*, not *proven*. |
| **Surface** | `charts/golden-service` 1.x · Crossplane XRDs `v1` · `reusable-build-sign.yaml@v1` · Kyverno policy set v1 (D-014) |
| **Decisions** | [Decision Log](adr/README.md) · [ADR-0010 versioning](adr/0010-contract-versioning.md) |

This is what the platform promises an app team, and what it asks in return. The four promises and their names come from
the AKS Engineering Blog (F2, F16). How each promise is delivered is this repo's design. Tools fulfill the contract; they
don't define it (F17).

**What an app team provides:** an `app` name and an `env`; a container that builds from a Chainguard base through
`reusable-build-sign.yaml`; `golden-service` chart values; and, for dependencies, an XR. Everything else (team, owner,
cost center, labels, tags, identities) is derived from the team definition in `platform/tenancy/teams/<team>.yaml`
(D-017, D-028).

---

## P1 A place to run

Blog meaning: "Your app gets its own boundary"; "You can request an environment" (F16).

| v1 guarantees | Delivered by | Proven by |
|---|---|---|
| One namespace per team per env (`<team>-<env>`), created from the team definition, with namespaced RBAC bound to the team's Entra group | Tenancy render, Kubernetes RBAC | Cross-tenant deny test for the Kubernetes API (D-025) |
| **Network boundary:** default-deny ingress and egress per namespace; L3/L4 allows by label and port; DNS egress to kube-dns; ingress only from the gateway | Cilium CNI + `CiliumNetworkPolicy` (D-021, D-029) | `tests/e2e/network-contract/`, run on kind, managed AKS and byo AKS (D-027) |
| Self-service dependencies through a namespaced XR (first: `PostgreSQLInstance`), the same API on kind (`local`) and AKS (`azure`) | Crossplane v2, namespaced managed resources only (D-024) | `crossplane resource validate` (D-040); XR lifecycle e2e |
| **"Ready" means usable:** the app connects with the brokered credential, survives a credential rotation, and leaves nothing behind after deletion | Crossplane `Usage`, `deletionPolicy: Delete`, per-tenant resource group (ADR-0002) | XR lifecycle e2e, steps 1–5 in [ADR-0002](adr/0002-crossplane-v2-external-resources.md) |
| Cloud credentials never exist on the workload cluster (split AKS) | Control/workload split (ADR-0001) | Split-topology isolation check (AKS only) |

**Not guaranteed in v1:** node sizing choices; Kubernetes versions chosen by the app team; dependencies other than
PostgreSQL (Redis is a catalog-expansion example only).

## P2 An identity

Blog meaning: "Your app reaches Azure services without a stored secret"; "Your app gets an HTTPS URL" (F16).

### App identity (D-022, [ADR-0008](adr/0008-application-workload-identity.md))

| v1 guarantees | Value |
|---|---|
| One user-assigned managed identity (UAMI) **per app per environment** | Created by the platform through the namespaced `AppIdentity` XR |
| Federated to the app's own ServiceAccount | Subject `system:serviceaccount:<team>-<env>:<app>`; issuer = the workload cluster's OIDC issuer; the ServiceAccount is rendered by `golden-service` |
| Role scope | Only the app's own resources (e.g. a data-plane role on one database or one Key Vault), never the resource group or the subscription |
| App teams **declare what they need**; they **never write role assignments** | The team declares `AppIdentity` (its name is the app); a database names its one owning app (`PostgreSQLInstance.spec.app`, immutable, D-102), and the platform creates that app's least-privilege database role (D-098) |
| Only the app's own ServiceAccount carries its identity | Every pod in a team namespace runs as the ServiceAccount named after its app (`serviceaccount-matches-app`, D-104) |
| The app receives its identity without a stored secret | `identity.enabled: true` in golden-service mounts the ServiceAccount's token (audience `api://AzureADTokenExchange`) and sets `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_FEDERATED_TOKEN_FILE` and `AZURE_AUTHORITY_HOST`, which Azure SDKs read; the IDs arrive from the `AppIdentity` through the team's store. The chart renders this itself, so the pod spec doesn't depend on the AKS webhook. On AKS the app may reach Microsoft Entra ID on TCP 443 (to `world` until the L7/FQDN profile narrows it, D-021) (D-105) |
| Lifecycle | Owned by the app's `team`, tagged, listed in the catalog, deleted with the app |
| First proven dependency | Azure Database for PostgreSQL Flexible Server with Entra authentication |

**Proven by (AKS release gate):** allow (the app's own query succeeds with an Entra token); deny (another team's identity
is refused); deny (another app in the same team is refused by the database, D-102); deny (a different ServiceAccount in the
same namespace gets no token); cleanup (no orphaned UAMI, federated credential, role assignment or database role). AKS
support isn't declared until all of them pass.

### HTTPS URL and network feature set (D-027, [ADR-0003](adr/0003-cilium-ebpf-and-gateway-api.md))

The app depends only on `HTTPRoute` (and `CiliumNetworkPolicy`, under P1). The `GatewayClass` differs by profile; the
app's manifests don't.

| Profile | Gateway controller | Pinned |
|---|---|---|
| `managed` (AKS default) | Envoy Gateway | Envoy Gateway v1.9.0 |
| `byo` (AKS) | Cilium Gateway | Cilium v1.20.0 |
| kind | Cilium Gateway | Cilium v1.20.0 |

All profiles pin **Gateway API v1.6.1** as the conformance basis. Both controllers are v1.6.1 conformant in the GATEWAY-HTTP,
GRPC and TLS profiles with zero failures (F14). The installed patch versions (for example Gateway API CRDs v1.6.3, which
Cilium 1.20 requires) follow the pin rule in D-039 and are listed in the
[Version pins](adr/README.md#version-pins) table; the network-contract suite re-proves every promised feature on them.

**Promised route features (v1):**
1. HTTPS listener with a cert-manager certificate
2. Host and path-prefix matching
3. Header matching
4. Weighted backends (manual canaries; see D-032)
5. Request and response header modifiers
6. HTTP → HTTPS redirect

Any other route feature is outside v1, even if one controller supports it.

**Promised policy semantics (v1):** listed under P1. **Optional L7/FQDN add-on profile:** L7 HTTP rules and FQDN egress. Free
on `byo` and kind; requires ACNS on `managed` (F3, D-021), which is a stated cost of the profile, not part of the baseline.

**Opt-in edge:** Azure Front Door Premium + WAF (`enable_edge_waf`, off by default), with origin lock (D-007). It is this repo's
extension.

**Proven by:** one Chainsaw suite, `tests/e2e/network-contract/`, runs every route feature and policy semantic unchanged
on kind (every PR), managed AKS and byo AKS. It also asserts that the controller versions match the pins.

## P3 A way to see what it's doing

Blog meaning: "You can see what your app is doing"; "Your team knows what it spends"; "You can find what's available" (F16).

| Signal | Where it surfaces | Access needed |
|---|---|---|
| Admission denial | Kyverno message (what, why, fix, docs link) on the PR / sync status | Git only |
| `PolicyReport` | Team namespace and a Backstage tab | Namespace `view` |
| Argo CD sync and health | Argo CD UI scoped by the team's AppProject; PR commit status | Team AppProject role |
| XR conditions | Backstage card (per-user credentials on AKS) | The user's own Kubernetes RBAC |
| Metrics and flows | The team's own Grafana organization; its data source returns only the team's namespaces | Grafana org membership |
| Cost | OpenCost by `team`, `app`, `env` | Grafana org / Backstage |
| Logs | `kubectl logs` within the team's namespaces | Namespaced RBAC |
| All of the above | `scripts/idp-diagnose.sh <app> <env>` | Entra group → namespaced Role |

**Tenant isolation is enforced at each backend, not by filtering the UI (D-025).** A backend is exposed to developers only
after its cross-tenant deny test passes: Kubernetes API, Argo CD, Backstage on AKS, Grafana/Prometheus, flows.

**Not guaranteed in v1:** aggregated log search and distributed tracing (D-033); tenant access to the Hubble UI (platform-only).

## P4 A safe way to ship

Blog meaning: "Your images get scanned for vulnerabilities"; "A rejected change tells you how to fix it"; "You ship by merging a pull request";
"A bad release doesn't reach everyone" (F16).

| v1 guarantees | Delivered by |
|---|---|
| You ship by merging a PR. Argo CD syncs it; nobody runs `kubectl apply` | Argo CD, per-team AppProject |
| Every image is built from a verified Chainguard base, scanned, signed keyless, and attested (SPDX SBOM, SLSA provenance, `base-image` digest) | `reusable-build-sign.yaml@v1` ([ADR-0005](adr/0005-chainguard-images-and-cosign-enforcement.md)) |
| Images, signatures and attestations are stored in GHCR | D-031 |
| **Admission binds three things:** the signer (pinned reusable workflow), the caller repo and ref (from signed provenance, allowlisted for the namespace's team), and the exact base digest (in the platform's verified set) | Kyverno `verifyImages` (D-026) |
| **Fail closed:** `failurePolicy: Fail`. If verification is unavailable, new or changed pods are rejected and running pods are untouched. Recently verified digests keep deploying through short outages via Kyverno's success cache (F15) | Kyverno |
| Every denial says what failed, why, the fix, and a docs link | Kyverno policy set v1 |
| Base-image digest bumps arrive as Renovate PRs that must pass the app's tests | Renovate (D-019) |

**Not guaranteed in v1:** automated progressive delivery with analysis and automatic rollback (D-032). Weighted backends
let a team run a manual canary through Git.

---

## Versioned surface and change rules (D-014, D-036, [ADR-0010](adr/0010-contract-versioning.md))

| Surface | v1 identifier |
|---|---|
| `charts/golden-service` | chart `1.x` |
| Crossplane XRDs (`platform.example.org`) | API version `v1` |
| `reusable-build-sign.yaml` | `@v1` |
| Kyverno policy set | `v1` |

| Change | Version bump | Requirements |
|---|---|---|
| Additive (new optional value or field, new policy in `Audit`) | Minor (`1.x`) | Changelog entry |
| Removal, rename, newly required field, `Audit` → `Enforce` that rejects previously valid manifests, change to the admission binding | Major (`2.0`) | ADR + migration guide; old XRD version served alongside the new one |
| Deprecation | — | Announced ≥ 1 minor release before removal; runs as an `Audit` warning (visible in `PolicyReport` and Backstage) first |

**Support window:** the current and previous major. **Adoption** is measured through the
`platform.example.org/contract-version` label on every app object (ADR-0007).

### Changelog

**Unreleased: 1.1.** Cut as one release once the `AppIdentity` kind journey passes (ADR-0013); until then the chart stays
`1.0.0` and the `contract-version` label stays `"1.0"`.
- XRD `AppIdentity` v1: an app's cloud identity, declared in `tenant-<team>-<env>`; its name is the app (D-104).
- XRD `PostgreSQLInstance`: optional `spec.app`, the database's owning app, immutable once set (D-102, D-104).
- Policy set: `serviceaccount-matches-app` (Deny). It rejects nothing golden-service renders, which sets the ServiceAccount
  and the app label from the same value (D-104).
- Policy set: `tenant-namespace-xrs-only` rejects a `PostgreSQLInstance` named `appidentity-*`, the only name that collides
  with identity entries in the team's store. Such a name was valid before; no request in this repo uses it (D-104).
- golden-service: optional `identity.enabled` (D-105).

**1.0:** the initial v1 surface (D-014).

## RACI (D-037)

R = responsible, A = accountable, C = consulted, I = informed.

| Activity | Platform team | App team |
|---|---|---|
| Team definition (`teams/<team>.yaml`: owner, cost center, data classification) | A (reviews and merges) | R (proposes the PR) |
| Contract surface (chart, XRDs, workflow, policy set) and its versioning | A, R | C (on breaking changes), I |
| Cluster lifecycle, upgrades, CNI, gateway, Argo CD, Kyverno, Crossplane, ESO, observability stack | A, R | I |
| Compositions and the Azure resources they create | A, R | C |
| App code, `golden-service` values, HTTPRoutes, declared dependencies | C | A, R |
| App SLOs and alerts | C (provides the templates) | A, R |
| Data in the app's database (schema, migrations, contents) | I | A, R |
| Backup and restore of composed databases | A, R (configuration) | C (restore tests for their data) |
| Policy exceptions and break-glass | A (approves, time-boxes) | R (requests, with owner and expiry) |
| Cost within the team's allocation | I (publishes the reports) | A, R |
| **The 3 AM page: app SLO or symptom alert** | C (escalation path) | **A, R (app team's on-call)** |
| **The 3 AM page: platform component down** (gateway, Argo CD, Kyverno, Crossplane, ESO, observability, cluster) | **A, R (platform on-call)** | I |
| **The 3 AM page: admission verification unavailable** (registry, Fulcio/Rekor) | **A, R** (runbook; time-boxed `PolicyException` if needed) | I |

Paging routes use the `owner` derived from the team definition (D-028). The blog asks teams to decide "who answers the 3 AM
page" (F17). This table is that decision for v1.

## Escape hatches

Every escape hatch goes through Git, has an owner, and expires or is reviewed. None needs `cluster-admin`.

| Need | Escape hatch | Approval | Source |
|---|---|---|---|
| Isolation beyond a shared workload cluster | Your own workload cluster, registered with `hosts-workloads` in its own workload group, which your team file assigns your envs to (D-079) | Platform team | ADR-0001 |
| A resource shape the XRD doesn't offer | Request a new composition variant | Platform team | ADR-0002 |
| Adopt an existing cloud resource | Observe-only import (`managementPolicies`) | Platform team | ADR-0002 |
| Service-to-service mTLS identity (mesh) | Open an ADR; not in v1 | Platform team | ADR-0003 |
| L7 HTTP or FQDN egress policy | Opt into the L7/FQDN add-on profile (ACNS cost on `managed`) | Platform team | D-021 |
| A WAF false positive | Per-route WAF exclusion PR with owner and expiry | Platform team | ADR-0004 |
| A policy blocks a legitimate case | Time-boxed `PolicyException` with owner, reason and expiry | Platform team | ADR-0005 |
| A language major pinned beyond `:latest` | Paid Chainguard versioned tags | Platform team (budget) | D-019 |
| Temporary elevated access during an incident | Entra PIM time-boxed elevation, audited | Platform team | ADR-0006 |
| A dependency that can't use Entra auth | ESO-brokered credential, declared in `catalog-info.yaml` with owner and review date | Platform team | ADR-0008 |
| Extra team-specific tags | Allowed; the required keys can't be removed | — | ADR-0007 |
| Can't migrate before a major's support window ends | Time-boxed exception PR with owner and expiry | Platform team | ADR-0010 |

## Failure and recovery ([ADR-0006](adr/0006-self-service-diagnostics-and-rbac.md))

For every failure the platform shows **what failed, at which step, the current state, and the next action**, inside the
team's own scope. A fix is always a Git change.

| Failure | Step | Current state (where shown) | Next action | Access needed |
|---|---|---|---|---|
| Image unsigned, wrong signer, caller not allowlisted, or base digest not verified | Admission | Kyverno denial on the Argo sync and PR status; `PolicyReport` | Build through `reusable-build-sign.yaml@v1` from an allowlisted repo and ref; rebase onto a verified base digest. The message links the docs | Git only |
| Manifest violates a policy (e.g. missing limits, overridden labels) | Admission | Kyverno message: what, why, fix, docs link | Fix the values in the PR | Git only |
| Sync fails (invalid manifest, AppProject violation) | Sync | Argo CD app status; PR commit status | Fix the manifest in Git | Team AppProject role |
| Rollout unhealthy (crash loop, failing readiness probe) | Rollout | Argo CD health; pod events and logs in the namespace; `idp-diagnose.sh` | Revert the PR, or fix and re-merge | Namespace `view` |
| XR stalled (quota, invalid parameter, provider error) | Provisioning | XR conditions on the Backstage card; `idp-diagnose.sh` | Fix the XR parameters in Git, or escalate a provider fault to the platform on-call | The user's own RBAC |
| Connection secret not synced | Secret delivery | `ExternalSecret` status in the namespace | Usually upstream: check the XR. If the XR is `Ready`, it's a platform page (ESO / Key Vault) | Namespace `view` |
| App can't get a token or is refused by its database | Identity | Pod logs; `AppIdentity` XR conditions | Check the declared dependency in Git; if it's correct, it's a platform page | Namespace `view` |
| Verification service unavailable (registry, Fulcio/Rekor) | Admission | Kyverno denial naming the unreachable service | Wait, or the platform on-call applies the break-glass `PolicyException` | — |

**Proven by:** for each scenario, a Chainsaw e2e test runs the diagnosis as a team-scoped identity. It asserts that the failing
step and the remediation hint are shown, and that no cluster-scoped read was needed.

## Success metrics (D-038)

**No numeric targets until a baseline exists.** Baselines are taken once Phase 6's pipelines can measure them. Each metric
has one named source, so the number can be reproduced.

| Metric | Definition | Source |
|---|---|---|
| Adoption | Share of a team's services carrying `platform.example.org/contract-version`, by version | Kubernetes labels (ADR-0007) |
| Time to first deploy | From the Backstage template run to the first `Healthy` Argo CD status for the new app | Scaffolder task timestamp + Argo CD health history |
| Change lead time | Commit → deployed (DORA, F22) | Git commit time → Argo CD sync time |
| Deployment frequency | Deployments per period (DORA, F22) | Argo CD sync history |
| Failed deployment recovery time | Time to recover from a deployment that needs immediate intervention (DORA, F22) | Argo CD health → next `Healthy` |
| Change fail rate | Share of deployments that need immediate intervention (DORA, F22) | Reverts and rollbacks in Git / Argo CD |
| Deployment rework rate | Share of unplanned deployments caused by a production incident (DORA, F22) | Deployments linked to incidents |
| Ticket deflection | Platform tickets per team per month, before and after self-service | Ticket system tags (baseline at adoption) |
| Developer satisfaction | A quarterly survey with a **fixed question set**, so results stay comparable (F19) | Survey tool |

The CNCF model warns about Goodhart's Law (F19). These metrics inform the roadmap; they aren't team targets.

## Where kind deviates

**Identity (ADR-0008) is the one contract promise kind can't deliver as written.** kind has no Entra federation. On kind,
the chart renders the same ServiceAccount, and the `local` PostgreSQL composition uses a brokered password delivered through
the local SecretStore. With `identity.enabled`, kind mounts a real projected token, but the identity Secret's IDs are
placeholders and nothing exchanges the token; journey J5 checks the mounted token's issuer, subject and audience against
the `AppIdentity`'s federation record instead (D-105, D-107). Real federation is an **AKS release gate**.

Related demo limitation (not a promise kind is expected to keep): Backstage on kind uses a read-only service account limited
to tenant namespaces, because there's no Entra ID. It is labeled as such and **never presented as tenant isolation**.
Per-user Backstage isolation is promised on AKS only (D-025).

## Stated gaps in v1

| Gap | Decision |
|---|---|
| Automated progressive delivery (analysis, automatic rollback) | D-032 |
| Development environments; messaging and event services | D-033 |
| Aggregated logs and distributed tracing | D-033 |
| Dependencies other than PostgreSQL | ADR-0002 (catalog expansion) |
| More than one database per app (`dependencies.postgres` takes one entry in v1) | D-071 |
| Credentials isolated per app within a team and env on kind (the kind vault is shared by the team's apps in that env; per-app scoping is the AKS identity gate) | D-071, ADR-0008 |
| Workloads other than an HTTP service: slow-starting inference, queue-driven jobs, stateful brownfield services, serverless or microVM isolation | Supported baseline below |
| Brownfield adoption (existing namespaces, existing cloud resources, durable data) | Supported baseline below |
| Team deploy-repo PR checks (render the values, evaluate current policy before merge); on kind the journeys merge first and read the post-merge status | Phase 6 (with Renovate and `decision-log-check`) |

**Supported baseline (v1).** golden-service runs one stateless HTTP service per app: a Deployment and Service, an HTTP
container with liveness and readiness probes, a read-only root filesystem, Pod Security `restricted`, fixed CPU and memory
requests, one HTTPRoute and at most one PostgreSQL dependency. Anything else needs a decision before a team adopts it: a
separate profile or chart has to state its lifecycle, identity, diagnostics and operator support, and prove them the way
the journeys do. Brownfield adoption is out of v1: applying tenancy defaults to an existing namespace can change its
network and Pod Security behavior, and deleting an XR deletes its data (J4 proves this for a disposable database).
Adoption needs an inventory, an ownership handoff, an `Audit` phase before enforcement and an observe-only import
(`managementPolicies`, ADR-0002), and durable data needs a proven restore first.
