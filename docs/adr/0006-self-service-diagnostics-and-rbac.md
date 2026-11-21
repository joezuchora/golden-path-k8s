# ADR-0006: Self-service failure diagnostics and RBAC without `cluster-admin`

- **Status:** Proposed
- **Date:** 2026-11-20
- **Contract promise:** P3 A way to see what it's doing
- **CNCF capability domain(s):** Application observability; Web portals for provisioning and observing capabilities; Identity and secret services
- **Related decisions:** D-009 (Revisited), D-025, D-010, D-041, D-050, D-061

## Context
A useful test of an abstraction is what happens when something fails. Developers must be able to see what
failed, at which step, which dependency is blocked, the current rollout or reconciliation state, and the next
action, without `cluster-admin` and without a ticket. The AKS blog's equivalents are "A rejected change tells
you how to fix it" (Deployment Safeguards on AKS, Kyverno as bring-your-own; F16), and AKS desktop, whose AI
assistant "works with the developer's own identity and RBAC, nothing more", with access "scoped to its namespace" (F17).
Fixes are made through Git. Managed Prometheus access is per workspace or cluster, not per namespace (F8). The
Hubble UI is not multi-tenant.

## Decision drivers
- Least privilege.
- Every failure signal visible within the team's own scope.
- Git as the only way to fix things.

## Options considered
| Option | Pros | Cons |
|---|---|---|
| Ticket the platform team | No access to design | Slow; the platform team becomes the bottleneck |
| Broad cluster read access | Easy | Leaks other tenants' data; fails least privilege |
| **Namespace-scoped RBAC + Backstage + Argo AppProjects + PolicyReports** | Least privilege; one portal | Needs integration work |
| **AKS-native:** AKS desktop / Container Insights / Application Insights | Managed | Namespace scoping is limited (F8) |

## Decision
| Signal | Where it surfaces | Access needed |
|---|---|---|
| Admission denial | Kyverno message: what, why, fix, docs link | Git only |
| `PolicyReport` | Team namespace and a Backstage tab | Namespace `view` |
| Argo CD sync and health | Argo CD UI scoped by AppProject; PR commit status via notifications | Team AppProject role |
| XR conditions | Backstage card (Kubernetes plugin, per-user credentials; see below) | The user's own Kubernetes RBAC |
| Flows and metrics | Team's own Grafana organization, with a data source that only returns that team's namespaces (Hubble in byo/kind; ACNS in managed) | Grafana org membership |
| All of the above in one command | `scripts/idp-diagnose.sh <app> <env>` | Entra group → namespaced Role |

**Authorization lives at the data source or backend, not in the UI (D-025, revised after external review).** Filtering a
view isn't access control. The earlier "service account filtered by catalog ownership" design is withdrawn because:
- Grafana: "Users with the Viewer role can enter any possible query in any of the data sources available in the
  organization", and per-data-source permissions are an Enterprise feature (F13).
- Backstage `serviceAccount` mode: "anyone that is logged in into your Backstage app will be granted the same access to
  Kubernetes objects", "including guest users". The permission framework "can disable the use of the `proxy` endpoint"
  (F13); the docs don't present it as a per-tenant filter on what the plugin reads.

Enforcement per backend:

| Backend | Enforcement |
|---|---|
| Kubernetes API | Entra group → namespaced `Role`/`RoleBinding` per team (first in the build order) |
| Argo CD | One AppProject per team, with RBAC bound to the team's Entra group |
| Backstage, on AKS | `aks` client-side auth provider: client-side providers "authenticate a _user_ with the cluster", "getting only the kubernetes permissions granted to that specific user" (F13, wording corrected in D-041), so Kubernetes RBAC applies per user. The `kubernetes.proxy` permission is denied by policy |
| Backstage, on kind | There's no Entra ID, so this is a **documented demo limitation**: a read-only service account limited to tenant namespaces. It's labeled as such in the UI and the docs, and never presented as tenant isolation |
| Grafana / metrics | One Grafana organization per team, each with its own Prometheus data source fronted by a namespace-enforcing proxy (prom-label-proxy) that injects `namespace=~"<team namespaces>"` |
| Flows | Same per-team proxy path; Hubble UI is platform-only, not exposed to tenants |

Each backend is enabled for developers only after its cross-tenant deny test passes.

## Consequences
- Positive: most failures are diagnosed and fixed by the owning team.
- Negative: dashboards and plugins need tenant filtering; the diagnostics script must be kept in step with each component.
- Escape hatch: time-boxed elevation through Entra PIM (the break-glass runbook); every elevation is audited.

## Fitness check
- **Diagnosis:** for each failure scenario (unsigned image, missing limits, stalled XR, degraded rollout), a Chainsaw
  e2e test runs the diagnosis steps as a team-scoped identity. It asserts that the failing step and the remediation
  hint are shown, and that no cluster-scoped read was needed.
- **Cross-tenant denial: the main silent-failure guard.** For **every backend** (Kubernetes API, Argo CD,
  Backstage on AKS, Grafana/Prometheus, flows), a test logs in as Team A, requests Team B's data, and asserts
  that the request is **denied or returns empty**. A backend without a passing deny test is not exposed to developers.
