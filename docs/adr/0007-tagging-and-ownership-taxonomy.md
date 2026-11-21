# ADR-0007: Tagging, labeling and ownership taxonomy

- **Status:** Proposed
- **Date:** 2026-11-20
- **Contract promise:** P1 A place to run · P3 A way to see what it's doing
- **CNCF capability domain(s):** Infrastructure services; Application observability
- **Related decisions:** D-010, D-017, D-028, D-044, D-055, D-063

## Context
Cost allocation (OpenCost, Azure cost analysis), ownership (Backstage `spec.owner`), paging (who answers at
3 AM, from the RACI) and audit all depend on the same metadata. When Azure tags, Kubernetes labels and catalog
fields drift apart, cost and ownership reports stop being trustworthy.

## Decision drivers
- One source of truth for ownership.
- Enforced at creation time, not cleaned up afterwards.
- Usable by FinOps and incident routing.

## Options considered
| Option | Pros | Cons |
|---|---|---|
| **AKS-native:** Azure Policy tag inheritance only | Managed; covers Azure resources | Doesn't cover Kubernetes objects or the catalog |
| Kyverno labels only | Covers Kubernetes | Doesn't cover Azure resources |
| **One taxonomy enforced at every layer** | Consistent metadata from end to end | More policies to maintain |

## Decision
A single taxonomy, with the same keys used as Azure tags and as `platform.example.org/*` labels:
`owner`, `team`, `app`, `env`, `cost-center`, `contract-version`, `data-classification`.

**`team` is the authoritative ownership key (D-028).** It names the team definition file and the Backstage Group, and it
decides RBAC, AppProject, cost allocation and paging. `owner` is **derived** from that team definition: it's the team's
Entra group / on-call alias, used for routing, and is never set independently. If they disagree, `team` wins and the
policy rejects the object.

**Values are derived, never typed by developers (D-017).** The only source of truth for `team`, `owner`,
`cost-center` and the default `data-classification` is the team definition, `platform/tenancy/teams/<team>.yaml`.
It is changed by a reviewed PR (journey O1).

```
teams/<team>.yaml ──► tenancy render ──► namespace labels (control tenant-<team>-<env> + workload ns)
                                              │
        Backstage template (app, env only) ───┤
                                              ▼
              Kyverno mutate: copy namespace labels onto every object; validate: reject overrides
                                              │
        Crossplane composition (go-templating ExtraResources reads the XR's Namespace, D-044)
                                              ▼
              Azure tags on every composed resource + per-tenant RG  ◄── Azure Policy: require + inherit
                                              │
              OpenCost: in-cluster allocation by labels; out-of-cluster Azure cost by tags
```

| Layer | How the keys get there |
|---|---|
| Namespaces | Rendered from the team definition by tenancy; namespace labels are platform-owned (Kyverno blocks tenant edits) |
| Kubernetes objects | Kyverno mutates namespace labels onto objects and rejects conflicting values; the `golden-service` chart sets `app` |
| Azure resources | Crossplane compositions read the XR's Namespace (go-templating `ExtraResources`, D-044) and stamp every tag; XRD schemas have no tag fields, so a developer can't override them; Azure Policy requires the tags at the RG |
| Backstage | The template asks only for `app` and `env` and takes `spec.owner` from the catalog group, which is synced from the team definitions |
| OpenCost | Label-based allocation (`team`, `app`, `env`, `cost-center`) for in-cluster spend; Azure cloud-cost integration uses the same tag keys for out-of-cluster spend |

**Coverage per enforcement layer (D-028).** Anything outside this table is out of scope for v1 and listed as such
in the docs.

| Layer | Covers | Doesn't cover (stated gap) |
|---|---|---|
| Kyverno (validate + mutate) | `Namespace` (platform-owned labels); `Deployment`, `StatefulSet`, `DaemonSet`, `Job`, `CronJob` **and their pod templates**, so Pods inherit; `Service`, `HTTPRoute`, `PersistentVolumeClaim`, `ExternalSecret`, `ServiceAccount`; every namespaced XR kind under `platform.example.org` | Pods created outside a controller (blocked by the baseline policy); cluster-scoped platform objects (platform-owned, labeled `team: platform`) |
| Crossplane compositions | Every composed Azure managed resource that supports tags, plus the per-tenant `ResourceGroup` | Azure child resources that don't support tags (e.g. `FlexibleServerDatabase`, `FlexibleServerFirewallRule`); they're attributed through their parent's tags |
| Azure Policy | Tenant resource groups (require all keys) and all taggable resources in them (inherit from the RG; audit on missing keys) | Resources outside tenant RGs (platform RGs carry `team: platform`) |
| Backstage | `Component`, `Resource`, `System` entities (`spec.owner` = the team's Group) | — |

Release tagging: semver git tags → image tags plus immutable digests, with OCI labels (`org.opencontainers.image.*`) set by the reusable workflow.

## Consequences
- Positive: cost, ownership and paging reports all use the same keys.
- Negative: a key can't be renamed without a major contract version.
- Escape hatch: extra team-specific tags are allowed; the required keys can't be removed.

## Fitness check
- `kyverno test` cases for missing or invalid labels.
- A CI check that every composition stamps every required tag.
- An Azure Policy compliance check in the AKS nightly.
- An OpenCost report grouped by `team` with no unallocated namespaces.
