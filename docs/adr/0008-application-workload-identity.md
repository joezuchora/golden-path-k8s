# ADR-0008: Application workload identity: how an app authenticates to Azure

- **Status:** Proposed
- **Date:** 2026-11-20
- **Contract promise:** P2 An identity
- **CNCF capability domain(s):** Identity and secret services; Security services
- **Related decisions:** D-022, D-010, D-028, D-029, D-082, D-086

## Context
Promise 2 is, in the blog's words, "An identity": "Your app reaches Azure services without a stored secret", delivered
on AKS by workload identity (F16).
ADR-0002 uses Workload Identity only for ESO's secret sync. An external review (2026-11-20) pointed out that the
plan never said how the **app itself** authenticates to an Azure dependency, or who owns that binding. Without
this, "secretless" is a claim about the platform's plumbing, not a promise to app teams.

## Decision drivers
- No stored credentials for Azure-native dependencies.
- Least privilege, scoped to one app in one environment.
- The binding is owned and reviewable, not hand-made.
- A provable deny case, not only an allow case.

## Options considered
| Option | Pros | Cons |
|---|---|---|
| Connection strings / keys via ESO | Works everywhere | A stored secret; rotation burden; contradicts the promise |
| **AKS-native:** Microsoft Entra Workload ID (federated credential on a user-assigned managed identity) | No secrets; Microsoft-supported; token exchange via the cluster OIDC issuer | Needs real federation, so it can't be fully reproduced on kind |
| Shared team identity | Fewer identities | Blast radius is the whole team; one app can reach another's data |
| Node / kubelet identity | Zero setup | Every pod on the node shares it. Rejected |

## Decision
**One user-assigned managed identity (UAMI) per app per environment, federated to that app's ServiceAccount.**

| Element | Value |
|---|---|
| Kubernetes ServiceAccount | `<app>` in namespace `<team>-<env>`, created by the `golden-service` chart, annotated with the UAMI client ID |
| Federated credential subject | `system:serviceaccount:<team>-<env>:<app>`, issuer = the workload cluster's OIDC issuer |
| Azure role scope | Only the app's own resources in the tenant RG (e.g. a data-plane role on one Key Vault or one database), never the RG or the subscription |
| Who creates it | The platform. A Crossplane composition (`AppIdentity` XR, namespaced) creates the UAMI, the federated credential and the role assignments from the app's declared dependencies. App teams declare *what they need*; they never write role assignments |
| Who owns it | The app's `team` (ADR-0007): tagged, listed in the catalog, deleted with the app |
| First dependency proven | **Azure Database for PostgreSQL Flexible Server with Entra authentication**, the same resource ADR-0002 composes, so one journey proves identity and resource delivery together |

**kind behavior:** kind has no Entra federation. On kind, the chart renders the same ServiceAccount and the
`local` Postgres composition uses a brokered password (via the local SecretStore). This is documented as the
**one place kind deviates from the contract**. Real federation is an **AKS release gate**: AKS support isn't declared
until the fitness check below passes there.

**Phase 4 design (D-082, D-086, Proposed):** for the first dependency, the app's UAMI becomes the Entra administrator
of its own Flexible Server (one server per XR), so no SQL bootstrap job is needed; federated credentials are created
for every cluster in the env's workload group (D-079).
**Revisited (D-098):** the app's UAMI is no longer the administrator. A platform identity administers the server and a
platform job, running as it, gives each app's UAMI a least-privilege database role, following Microsoft's guidance not to
use the Entra administrator for regular operations (F61). The job's identity and network path are designed with the
`AppIdentity` XRD; the federated-credential design above is unchanged.

## Consequences
- Positive: no stored secret for Azure-native dependencies; per-app blast radius; identity lifecycle tied to the app.
- Negative: more identities to manage (one per app per environment), and federated-credential limits per UAMI;
  the kind and AKS behaviors differ for this one promise.
- Escape hatch: a dependency that can't use Entra auth falls back to ESO-brokered credentials. That requires an
  entry in the app's `catalog-info.yaml` naming the exception, with an owner and a review date.

## Fitness check (AKS release gate)
- **Allow:** the sample app, running as its own ServiceAccount, connects to its Postgres with an Entra token. The test passes only if a query succeeds.
- **Deny:** a pod in **another team's namespace** using its own federated identity tries the same database and is refused.
- **Deny:** a pod in the same namespace with a different ServiceAccount gets no token for the app's UAMI.
- **Cleanup:** deleting the app removes the UAMI, the federated credential and the role assignments. The test asserts that none are orphaned.
