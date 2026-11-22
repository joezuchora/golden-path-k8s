# ADR-0013: Subscription placement and vending

- **Status:** Proposed
- **Date:** 2026-11-22
- **Contract promise:** P1 A place to run
- **CNCF capability domain(s):** Infrastructure services; APIs for automatically provisioning capabilities
- **Related decisions:** D-017, D-024, D-079, D-083, D-088, D-099

## Decision

Deploy the reference platform into one existing Azure subscription, configured with the sandbox Terraform input
`subscription_id`. All teams and owners share that subscription. Keep the existing per-team and per-environment
resource groups, workload placement, workload identities, budgets and teardown controls.

At enterprise scale, a platform-owned Git mapping resolves a request's team, environment and offering to an approved
destination. A destination can be a workload landing zone, a platform-owned shared service, or an in-cluster service.
Platform automation consumes the approved mapping. Backstage collects requests and displays status, ownership, approved
offerings and cost estimates. The request and approved configuration live in Git.

## Metadata and ownership

| Record | Authoritative source | Owner |
| --- | --- | --- |
| Service and dependency request | Reviewed service deploy repository | Service team |
| Team owner, cost center, environments and workload group | Platform team definitions and reviewed deployment configuration | Platform team with the service owner |
| Approved destination | Platform-owned Git configuration. Azure destinations identify the subscription, resource group and any shared instance. In-cluster destinations identify the workload placement and service boundary. | Platform team |
| Subscription creation, billing scope and policy placement | Governed landing-zone workflow and Azure | Platform team, with delegated billing access and cloud governance approval |
| Deployed resources, effective access and actual spend | Azure and Kubernetes, surfaced through platform integrations | Platform and workload teams at their respective scopes |

Backstage can render and link these records. Applications submit a logical offering and environment through Git.
The backend derives the owner from approved metadata and resolves the destination. The approved target and
least-privilege provisioning identity must be bound together. Ambiguous, missing or unauthorized placements fail closed.
Keep runtime credentials out of the catalog and Git.

## Deployment and enterprise adoption

The existing [AKS setup](../getting-started.md#4-cloud-aks-phase-4) takes one subscription ID. A future deployment can
register existing landing zones first and later use a separate Terraform vending workflow to create them. The workflow
owns the billing scope, management-group placement, RBAC, networking and initial budget. It writes the approved
destination or hands it off to the platform mapping after creation. Workload teams own application operations and their
budget after handoff. Subscription creation privileges belong to the vending identity.

Prefer workload and environment boundaries for separate landing zones. Reuse a platform-owned destination for shared
AKS or approved shared data services. Keep application requests stable across these deployment models. Compare the
allocated share of shared infrastructure with extra capacity or other incremental spend before approving a request.
Protect resources already bound to a destination from implicit moves when metadata changes. Move them through an
explicit migration with owner approval.

Options considered were a fixed subscription, an app-supplied Azure destination, and platform-owned placement. The
chosen approach keeps the reference setup small, preserves the platform's security boundary, and supports adopting an
organization's existing landing zones. Enterprise adoption adds placement validation and separate provisioning scopes.
See Microsoft's [subscription vending implementation guidance](https://learn.microsoft.com/en-us/azure/architecture/landing-zones/subscription-vending)
for the Terraform-based Azure Landing Zones path.

## Fitness checks

- Verify two team environments resolve to the same configured subscription and distinct approved resource groups in
  the reference deployment.
- Verify enterprise fixtures route one team environment to its workload landing zone and another offering to a
  shared platform service. The placement check denies an unknown destination and an attempt to use another team's
  destination without an approved access grant.
- Verify changing the mapping cannot silently move or recreate a bound resource. Verify neither Backstage nor an app
  workload identity can create subscriptions.

The reference Terraform root currently deploys to a single subscription. Multi-subscription resolution and vending
are follow-on implementation work.
