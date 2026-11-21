# O1 Onboard a team

**Who:** an app team proposes; the platform team reviews and merges (RACI). **Promise:** P1 ("Your app gets its own
boundary") and P3 (tenant isolation at each backend, D-025). **Exit criterion 7** (cross-tenant deny for the Kubernetes
API and Argo CD). **Suite:** `tests/e2e/o1-onboard-team/`.

## What happens

1. The team opens a PR on the platform repo adding `platform/tenancy/teams/<team>.yaml`: team, owner, cost center, data
   classification, envs, identity groups, deploy repo, allowed image callers and quota.
2. The platform team merges it. The tenancy ApplicationSets (D-049) render, per capability:
   - **workloads:** namespace `<team>-<env>` with platform-owned labels and Pod Security `restricted`; the developers'
     `view` RoleBinding; ResourceQuota and LimitRange; the default-deny `CiliumNetworkPolicy`; the team's admission and
     label policies (D-055); the app-side secret store.
   - **control plane:** namespace `tenant-<team>-<env>` for XRs; the AppProject; the team's app and XR ApplicationSets
     (D-061); the vault and its writer store (D-064).
3. Nobody runs `kubectl`. Offboarding is a deliberate platform action (D-049, D-061).

## Cross-tenant deny (the suite's assertions)

| Backend | Allowed | Denied |
|---|---|---|
| Kubernetes API (impersonated groups, D-050) | team reads its own pods and logs | another team's namespaces; Secrets, even its own; any write (fixes go through Git); cluster-scoped reads |
| Argo CD API (team local accounts, D-050) | team sees its own project | another team's project (403), its apps (403), syncing them (403), the platform's apps (403); creating apps even in its own project |

A backend is exposed to developers only after its deny test passes (D-025). Backstage and Grafana get their deny tests
when they arrive (Phases 5 and 6, D-051).

## Where kind deviates

Identities are substitutes (D-050): impersonation stands in for Entra groups, and Argo CD local accounts are
pre-provisioned for the test teams (team-a, team-b). The authorization rules (RoleBindings, AppProject roles) are the ones
AKS uses.
