# ADR-0013: AppIdentity, tenant-scoped provider identities and database roles

- **Status:** Proposed
- **Date:** 2026-11-22
- **Contract promise:** P2 An identity
- **CNCF capability domain(s):** Identity and secret services; Security services; Infrastructure services
- **Related decisions:** D-022, D-024, D-025, D-079, D-081, D-082, D-086, D-094, D-098, D-099, D-102, D-104

## Context
ADR-0008 decided the shape of an app's identity: one user-assigned managed identity (UAMI) per app per environment,
federated to the app's ServiceAccount and created by a platform composition. This ADR decides how the platform builds it,
and closes two gaps the research for it found.

- **Database access (D-098).** D-082 made the app's UAMI the Entra administrator of its own server. Microsoft's guidance
  is not to use that role for regular operations, and only an Entra administrator can create Entra-authenticated users
  (F61). So a platform identity must administer the server and create each app's role.
- **One provider identity for every tenant.** Crossplane's Azure providers run as one UAMI that is Contributor on every
  tenant resource group, Network Contributor on the delegated subnet and Private DNS Zone Contributor on the one shared
  zone (D-082), used through the shared `ClusterProviderConfig default`. D-094 closed the admission path for a team's
  raw managed resources, but that one rule is all that stands between a tenant namespace and every tenant's resources.
  AppIdentity adds identity resources, which make a cross-tenant mistake worse: a federated credential on another team's
  UAMI is a takeover of that app's access.

Verified facts:
- **Provider resources (F62).** provider-upjet-azure v2.8.0 has namespaced `UserAssignedIdentity`,
  `FederatedIdentityCredential`, `RoleAssignment` and `FlexibleServerActiveDirectoryAdministrator`. The repo pins v2.8.4
  from Upbound's registry, which has no matching source tag; `crossplane resource validate` against the pinned package
  is the check.
- **Federated credentials (F62).** At most 20 per UAMI; issuer and subject must match the token, no wildcards; concurrent
  writes to one UAMI fail with HTTP 409, so they are created one after another; a token requested before a new
  credential has propagated fails (`AADSTS70021`), so token requests retry.
- **Provider configs (F63).** A namespaced managed resource's `providerConfigRef` has only `kind` and `name`, and
  defaults to `ClusterProviderConfig/default`. A namespaced `ProviderConfig` is looked up in the resource's own namespace
  only; a `ClusterProviderConfig` can be referenced from any namespace. `ProviderConfig` supports `OIDCTokenFile`
  credentials with its own `clientID`, `tenantID` and `subscriptionID`. The token file is the provider pod's, so each
  tenant identity federates to the provider's service account.
- **Database roles (F64).** `pgaadauth_create_principal_with_oid(roleName, objectId, objectType, isAdmin, isMfa)` creates
  an Entra role bound to an object ID (`service` for a managed identity's service principal); only an Entra administrator
  can run it. Permissions for a non-admin Entra role are granted like any role's. A pod exchanges its projected token for
  a database token at `login.microsoftonline.com/<tenant>/oauth2/v2.0/token` (client credentials, `jwt-bearer` client
  assertion, scope `https://ossrdbms-aad.database.windows.net/.default`). `cgr.dev/chainguard/postgres:latest-dev` is
  free, pulls anonymously and has psql, a shell and `wget`, but not curl.
- **Network.** The control cluster shares the environment's VNet with the PostgreSQL subnet, with no NSGs
  (`infra/modules/network`), so a job on the control cluster can reach a VNet-integrated server.

## Decision drivers
- Per-app least privilege (ADR-0008), and a per-tenant blast radius for every platform credential.
- Isolation enforced by the backend, not by one admission rule (D-025, D-094).
- Teams declare what they need; they never write role assignments, federated credentials or SQL grants.
- The same XRD API on kind and AKS; one stated kind deviation (ADR-0008).
- Delivered in slices that are each useful and testable on their own.

## Options considered
**Which identity Crossplane's providers use for a tenant**
| Option | Pros | Cons | Cost / operational load |
|---|---|---|---|
| One shared identity, `ClusterProviderConfig default` (today) | Simple | Reaches every tenant's resource group, the shared subnet and the shared DNS zone; isolation rests on one admission rule | Lowest |
| **A per-tenant provider UAMI through a namespaced `ProviderConfig`** (chosen) | A resource in `tenant-<team>-<env>` can only use that tenant's credentials, even if admission were bypassed | One UAMI per tenant/env, one federated credential per provider service account, a DNS zone per tenant | Moderate (Terraform) |
| **AKS-native:** Azure Service Operator with per-namespace credentials | Same isolation model, Microsoft-supported | Replaces the composition engine (ADR-0002) | High |

**Who administers the app's database server**
| Option | Pros | Cons | Cost / operational load |
|---|---|---|---|
| The app's UAMI (D-082) | No job; one identity | Against Microsoft's guidance (F61); the app gets rights it never needs | Lowest |
| Crossplane's shared identity | No new identity | One credential becomes database administrator for every tenant | Low |
| **A per-tenant database-admin UAMI** (chosen) | Blast radius is one tenant's servers; the job runs in the tenant's own namespace | One more identity per tenant/env | One UAMI and one federated credential per tenant/env |
| A per-server admin UAMI | Blast radius is one database | Twice the identities and credentials per database; more to compose and clean up | High |

**Who declares an app's AppIdentity, and which app a database grants**
| Option | Pros | Cons | Cost / operational load |
|---|---|---|---|
| The team, in `xrs/<env>/`; AppIdentity lists its databases (`spec.postgres`) (first choice, superseded by D-102) | Smallest change; several apps can share a database | Any app in the team can name any team database and get a role on it; the dependency is listed twice and can drift | None new |
| **The team, in `xrs/<env>/`; the database names its one owning app (`PostgreSQLInstance.spec.app`, immutable), and AppIdentity names only the app** (chosen, D-102) | A database grants exactly one app, chosen where the database is requested; matches one database per app (ADR-0008) and the Backstage catalog design | Sharing a database between apps needs a new request and an explicit data migration | None new |
| Generated by the platform from golden-service `dependencies` | One declaration; deleted with the app | A new control-plane ApplicationSet and chart; D-094's tracking-id rule changes | Medium |

**How a database role is created and removed**
| Option | Pros | Cons | Cost / operational load |
|---|---|---|---|
| A one-shot Job per AppIdentity | Simple | Nothing drops the role when the app goes away | Low |
| **A role-sync Job composed by the database** (chosen) | Converges the server's app role to the database's owning app, so removal is covered | The database composition reads the owner's AppIdentity; a Job per change | Low |
| crossplane-contrib provider-sql | Declarative roles | Can't call `pgaadauth_*` functions; Entra tokens as passwords expire within an hour | Medium |

## Decision
Three slices, in this order.

**1. Tenant-scoped provider identity (D-099).** Terraform creates, per tenant and env, a provider UAMI with Contributor on
that tenant's resource group, federated to each Azure provider's service account on the control cluster. Each tenant gets
its own PostgreSQL private DNS zone (`<tenant>.<prefix>.private.postgres.database.azure.com`, linked to the VNet) in its
resource group, and the shared delegated subnet grants tenant identities a custom role with only the subnet `join`
action. The tenancy chart renders a namespaced `ProviderConfig` named `tenant` in `tenant-<team>-<env>` with that UAMI's
client ID; every composed managed resource sets `providerConfigRef: {kind: ProviderConfig, name: tenant}`. **No
`ClusterProviderConfig` exists**, so a resource that omits the reference has no credentials and fails closed, and
`make validate` fails if any rendered manifest contains one. The shared Crossplane identity's roles are removed.

**2. `AppIdentity` XRD v1 (D-086, revised; ownership per D-102).** A team declares the app's identity next to its
database XR, and the database names the one app it serves:
```yaml
apiVersion: platform.example.org/v1
kind: AppIdentity
metadata: {name: hello, namespace: tenant-team-a-dev}   # the name is the app; no roles, grants or tags (D-017)
spec: {}
---
apiVersion: platform.example.org/v1
kind: PostgreSQLInstance
metadata: {name: orders-db, namespace: tenant-team-a-dev}
spec:
  app: hello                 # the owning app; immutable once set (XRD validation self == oldSelf)
```
`spec.app` is an additive, optional field on the PostgreSQLInstance XRD v1, so the API stays identical on kind and AKS
and existing requests keep working (ADR-0010). The `azure` composition requires it: without it, or when no AppIdentity of
that name exists in the namespace, the database is created but grants nothing, and the XR's status says why. The kind
path keeps its brokered password and doesn't require it. The `azure` composition creates the app's UAMI in the tenant resource group; one federated credential per cluster in
the env's workload group (subject `system:serviceaccount:<team>-<env>:<name>`), each created only after the previous one
is Ready (F62); and a Secret with the client and tenant IDs, delivered to the app's namespace like a database connection
(ADR-0002). The XR's status carries the UAMI's principal ID. The `local` composition renders the same Secret and a
federation record (issuer, subject, audience) that kind's e2e checks against real projected tokens; kind can't exchange
them with Entra, which stays the one stated deviation (ADR-0008).

**3. Database roles (D-098).** Terraform creates a per-tenant database-admin UAMI, federated to a platform ServiceAccount
in `tenant-<team>-<env>`. The `azure` PostgreSQL composition makes it the server's Entra administrator, and composes a
role-sync Job in the tenant namespace that runs as it (`chainguard/postgres:latest-dev`, digest-pinned; `wget` for the
token exchange, psql for SQL; F64). The desired role is the one for the AppIdentity named by `spec.app`, read through
the composition's extra resources together with its principal ID; the Job's name carries a hash of that, so any change
reruns it. It creates the role with `pgaadauth_create_principal_with_oid(<app>, <principalId>, 'service', false, false)`,
grants it connect and the application schema's privileges (no `CREATEDB`, no role management), and drops any other app
role on the server, so a role whose AppIdentity is gone doesn't linger. Deletion order: the grant is dropped before the
identity or the database is deleted, and the cleanup tolerates resources that are already gone; the AKS teardown drains
AppIdentity XRs as well as PostgreSQL XRs (D-102).

golden-service renders the projected service-account token itself (audience `api://AzureADTokenExchange`) and reads the
client and tenant IDs from the identity Secret, so it doesn't depend on the mutating webhook and renders identically in
`managed` and `byo` (D-086). A Kyverno rule requires a pod's `serviceAccountName` to equal its app label in team
namespaces, so another ServiceAccount in the same namespace can't stand in for the app.

**Progress.** Slice 1 is built (D-099). Slice 2 is built in part (D-104): the XRDs, both AppIdentity compositions, the
ServiceAccount policy and the issuers in the EnvironmentConfigs. golden-service consumes the identity behind the optional
`identity.enabled` value, with TCP 443 egress to `world` on the AKS profiles only (D-105). Journey J5 runs the kind
fitness checks for slice 2 on every PR (D-109). Slice 3 and the AKS release gate remain.

## Consequences
- Positive: per-app identity and least-privilege database access; every platform credential that touches tenant
  resources is scoped to one tenant, so isolation no longer rests on admission alone (D-094 becomes defense in depth).
- Negative / accepted trade-offs: two more UAMIs and a DNS zone per tenant/env, and one federated credential per provider
  service account for each tenant's provider UAMI; a Job and a network path into the PostgreSQL subnet, which D-082
  avoided; Entra administration on a VNet-integrated server needs outbound access to the `AzureActiveDirectory` service
  tag (F61), which the delegated subnet's NSG allows (D-103); a database serves one app, so sharing one means a new request and
  a data migration (D-102). Moving existing servers to per-tenant DNS zones means recreating them; nothing runs on Azure yet, so the
  move costs nothing today.
- Escape hatch: a dependency that can't use Entra auth falls back to ESO-brokered credentials, with an exception entry
  in the app's `catalog-info.yaml` naming an owner and a review date (ADR-0008).

## Fitness check
On kind (every PR):
- `make validate`: no rendered manifest contains a `ClusterProviderConfig`; every tenant namespace on the control
  cluster gets exactly one `ProviderConfig` named `tenant`, with its own tenant's client ID; every managed resource in
  the `azure` render tests sets `providerConfigRef.kind: ProviderConfig`.
- `kyverno test`: in a team namespace, a pod whose `serviceAccountName` differs from its app label is denied (pass and
  fail cases).
- Render tests for both compositions, and an e2e that applies an `AppIdentity` and checks that the identity Secret
  reaches the app's namespace; that a token for the app's ServiceAccount matches the federation record while tokens for
  another ServiceAccount and another team's ServiceAccount don't; and that deleting the XR removes what it created.
- Ownership render cases (D-102): a database whose `spec.app` names an existing AppIdentity renders exactly one role
  grant for it; a missing `spec.app`, a name with no AppIdentity, and an AppIdentity the database doesn't name render no
  grant; changing `spec.app` on an existing XR is rejected by the XRD.

On AKS (release gate, ADR-0008):
- **Allow:** the sample app connects to its database with an Entra token, and a query succeeds.
- **Deny:** another team's app, with its own identity, is refused by the database, not by the network.
- **Deny:** a second app in the same team gets a token as itself and reaches the same endpoint, and PostgreSQL rejects
  its login (D-102).
- **Deny:** the owning app's role can't run an administrative operation it was never granted (for example `CREATE ROLE`).
- **Deny:** a pod in the same namespace with another ServiceAccount gets no token for the app's UAMI.
- **Deny:** a managed resource in one tenant namespace that names another tenant's resource group fails authorization.
- **Cleanup:** deleting the XRs leaves no UAMI, federated credential, role assignment or database role behind.
