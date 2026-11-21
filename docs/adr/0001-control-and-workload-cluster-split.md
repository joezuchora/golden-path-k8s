# ADR-0001: Control cluster vs. workload cluster split

- **Status:** Proposed
- **Date:** 2026-11-20
- **Contract promise:** P1 A place to run · P4 A safe way to ship
- **CNCF capability domain(s):** Infrastructure services; Automation for delivering and verifying services
- **Related decisions:** D-002, D-005, D-023, D-060, D-079, D-078, D-085

## Context
Crossplane holds credentials that can create and delete cloud resources. Argo CD holds credentials that can
deploy to every cluster. Running both next to tenant workloads widens the blast radius and ties their
upgrade cadence to the apps'. The AKS blog recommends a Standard control cluster (Crossplane or kro plus
GitOps, patch upgrade channel, private API server) and separate workload clusters, which it runs on AKS Automatic (F17). On a laptop, Backstage,
Argo CD, Crossplane and Prometheus together need about 8–10 GB of RAM.

## Decision drivers
- Credential and blast-radius isolation.
- Independent upgrade cadence for the platform and for workloads.
- Cost (each extra cluster costs money).
- A local mode that matches production and costs nothing.

## Options considered
| Option | Pros | Cons |
|---|---|---|
| (a) Single cluster | Cheapest, simplest | Crossplane and Argo CD credentials share a cluster with tenant workloads; one upgrade cadence |
| **(b) Control + workload clusters, Argo CD as the hub** | Clear isolation; matches the blog | About one extra cluster of cost; cluster-secret management |
| **AKS-native:** (c) Fleet Manager hub + member clusters | Managed staged upgrades and resource placement | Still needs a GitOps and Crossplane home; more Azure-specific |
| **AKS-native:** (d) AKS Automatic workload clusters | Managed defaults, Deployment Safeguards | Default CNI is Azure CNI Overlay powered by Cilium, and "Bring your own CNI" is documented only for Standard (F23), so `cilium_mode = byo` (ADR-0003) isn't a documented option |

## Decision
Option (b) on AKS: one control cluster plus one workload cluster. On kind it collapses to one cluster.
AKS Automatic workload clusters are deferred and revisited if D-005 changes. Fleet Manager is documented as the
scale-out path for upgrade staging.

**Placement mechanism (D-023, revised after external review).** A single `role` key can't hold both values, and
Argo CD's default local cluster has no Secret, so label selectors can't match it. Instead:
- Every cluster, including the in-cluster target, is registered **declaratively** as an Argo CD cluster Secret.
- Each Secret carries independent capability labels: `platform.example.org/hosts-control-plane: "true"` (Crossplane,
  Backstage, Argo CD hub, ESO PushSecret) and `platform.example.org/hosts-workloads: "true"` (apps, gateway, Kyverno,
  observability).
- The kind Secret sets both labels; the AKS control and workload Secrets set one each. ApplicationSets select on
  one capability label each and never on cluster names.
- **Team apps (D-079, Phase 4):** each env is assigned to a workload group in the team file; cluster Secrets carry
  `platform.example.org/workload-group`, the team's app ApplicationSet selects `hosts-workloads` plus the group, and
  Application names carry the cluster, so two clusters in a group can't collide.
- **On the split (D-078, D-085):** External Secrets also runs on a control-only cluster (`external-secrets-push`) for
  the PushSecrets, and Argo CD reaches workload clusters with Workload Identity, so the hub stores no spoke credential.

## Consequences
- Positive: Crossplane and cloud credentials never exist on workload clusters, and the platform can be upgraded first.
- Negative: an extra cluster's cost; cross-cluster secrets need Key Vault as the shared broker (ADR-0002).
- Escape hatch: a team with special needs gets its own workload cluster, registered with the `hosts-workloads` label.

## Fitness check
- **Every PR (kind):** render all ApplicationSets against the kind cluster Secret and assert that each component
  is generated exactly once (no duplicates and none missing). A CI lint fails on any hardcoded cluster name.
- **Split AKS only:** assert that no Crossplane CRD, `ProviderConfig` or cloud-credential Secret exists on the
  cluster that has `hosts-workloads` without `hosts-control-plane`. This check deliberately doesn't run on kind,
  where co-location is by design.
