# ADR-0002: Crossplane v2 for external resources reconciled outside workload namespaces

- **Status:** Proposed
- **Date:** 2026-11-20
- **Contract promise:** P1 A place to run
- **CNCF capability domain(s):** Infrastructure services; Data services; APIs for automatically provisioning capabilities
- **Related decisions:** D-003 (Revisited), D-024, D-002

## Context
App teams need databases, caches and networks without filing tickets and without holding cloud credentials.
Crossplane v2.4 (F4) makes XRs and MRs namespaced, removes claims for v2 XRs, removes XR connection details and
native patch-and-transform (P&T), and notes that namespaced Azure MRs are "still being updated". The AKS blog
marks "You can request an environment" as "Not built in" on AKS and lists "Crossplane with OpenTofu, or kro with
Azure Service Operator (ASO)" as the bring-your-own path (F16). It says kro is "still pre-1.0" (F17).

## Decision drivers
- A declarative, self-service API that is continuously reconciled (drift correction).
- Cloud resources live outside workload namespaces and clusters (ADR-0001).
- The same API runs on kind at zero cost.
- Clean deletion with no orphaned cloud resources.

## Options considered
| Option | Pros | Cons |
|---|---|---|
| OpenTofu/Terraform pipelines | Mature, familiar | Not continuously reconciled; a ticket- or pipeline-shaped developer experience; state files |
| **Crossplane v2 XRDs + compositions** | K8s-native API, drift correction, multi-cloud, composition functions | Operational load of providers; Azure namespaced MRs still maturing |
| **AKS-native:** ASO alone | Microsoft-supported, full Azure coverage | Exposes raw Azure resources; no abstraction layer |
| **AKS-native:** kro + ASO | Lightweight abstraction | Pre-1.0 |
| Crossplane provider-opentofu | Reuses existing modules | Two reconcile models; opaque failures |

## Decision
Crossplane v2:
- **Namespaced XRs** (for example `PostgreSQLInstance.platform.example.org`) live in control-cluster
  `tenant-<team>-<env>` namespaces, never in workload namespaces.
- Each XRD ships two compositions, selected by label: `provider: azure` (resources in a per-tenant Azure
  resource group) and `provider: local` (in-cluster CloudNativePG for kind and previews).
- The pipeline uses `function-go-templating` + `function-auto-ready`.
- Connection details are an explicit composed `Secret` → ESO `PushSecret` → Key Vault → `ExternalSecret`
  in the workload namespace, authenticated with Workload Identity. On kind, a Kubernetes-backend SecretStore
  replaces Key Vault.
- Lifecycle: readiness via auto-ready conditions; drift is corrected continuously; `managementPolicies` is the
  documented escape hatch for observe-only; deletion uses `deletionPolicy: Delete`, Crossplane `Usage` for
  ordering, and the per-tenant resource group as the blast-radius boundary.
- **Namespaced managed resources only (D-024).** A namespaced XR "can only compose resources in the same namespace",
  so the earlier `LegacyCluster` fallback was invalid and has been removed. The `provider-upjet-azure` source has
  namespaced `v1beta1` APIs for everything the first compositions need: `dbforpostgresql` (`FlexibleServer`,
  `FlexibleServerDatabase`, `FlexibleServerFirewallRule`), `azure` (`ResourceGroup`), `keyvault` (`Vault`, `Secret`), and
  `cache` (Redis, for the catalog-expansion example; F12). Pin the provider version and run `crossplane beta validate`
  against the pinned CRDs before writing a composition.
- **"Ready" means the app can use it.** A dependency counts as delivered only when the consuming app connects with
  the brokered credential, survives a credential rotation, and leaves no database or brokered secret behind after deletion.

## Consequences
- Positive: one stable developer API regardless of backend; resources stay correct over time.
- Negative: Crossplane providers are a system to run and patch; connection secrets need several hops.
- Escape hatch: a team can request a new composition variant or an observe-only import of an existing resource.

## Fitness check
- `crossplane beta validate` in CI.
- A Chainsaw e2e test runs the full lifecycle:
  1. Create the XR and wait for `Ready=True`.
  2. Check that the `ExternalSecret` has synced into the workload namespace.
  3. **The sample app's readiness probe runs a real query** through the brokered credential.
  4. Rotate the credential (in Key Vault, or in the local SecretStore on kind) and assert the app reconnects after Reloader restarts it.
  5. Delete the XR. Assert that the database is gone, the tenant resource group is empty on AKS (or the CNPG cluster is gone on kind), the Key Vault secret and the `ExternalSecret` target are removed, and no Crossplane finalizers remain.
