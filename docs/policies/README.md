# Policy set v1

Kyverno policy set v1 is part of the Developer Contract v1 surface (D-014). It uses only the CEL policy types (ADR-0012,
D-042), fails closed (`failurePolicy: Fail`), and every denial says **what** failed, **why**, the **fix**, and links here.
Every policy has pass and fail cases under `platform/policies/tests/` (`make test-policies`).

| Policy | Type | Scope | Page |
|---|---|---|---|
| `image-admission-<team>` | ImageValidatingPolicy | the team's app namespaces | [image-admission](image-admission.md) |
| `allowed-registries` | ValidatingPolicy | every app namespace | [allowed-registries](allowed-registries.md) |
| `require-resources` | ValidatingPolicy | every app namespace | [require-resources](require-resources.md) |
| `require-controller` | ValidatingPolicy | every app namespace | [require-controller](require-controller.md) |
| `route-hostnames` | ValidatingPolicy | every app namespace | [route-hostnames](route-hostnames.md) |
| `serviceaccount-matches-app` | ValidatingPolicy | every app namespace | [serviceaccount-matches-app](serviceaccount-matches-app.md) |
| `tenant-namespace-xrs-only` | ValidatingPolicy | tenant namespaces on the control plane | [tenant-namespace-xrs-only](tenant-namespace-xrs-only.md) |
| `ownership-labels-<team>` (validate); `derive-labels-<team>`, `derive-labels-pods-<team>` (mutate) | ValidatingPolicy, MutatingPolicy | the team's namespaces | [ownership-labels](ownership-labels.md) |

Per-team instances are rendered by the tenancy chart from `platform/tenancy/teams/<team>.yaml` (D-055). The cluster-wide
policies come from `platform/components/kyverno-policies`. App policies cover the app namespaces (`<team>-<env>`); tenant
namespaces on the control plane (`tenant-<team>-<env>`), where only platform operators run pods (CloudNativePG, D-053),
are covered by `tenant-namespace-xrs-only` instead.

**Where a denial shows up:** Argo CD applies your manifests, so a denial fails the sync. The message appears on the Argo CD
application and, through Argo CD notifications, as a failed commit status on your deploy-repo commit (D-043). Background
scans also record results in `PolicyReport`s in your namespace (`kubectl get policyreports -n <team>-<env>`).

**Escape hatch:** a time-boxed `PolicyException` (`policies.kyverno.io`) with an owner, a reason and an expiry, approved by
the platform team (ADR-0005). Exceptions are platform-owned objects: an app team's AppProject can't create them.
