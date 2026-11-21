# ownership-labels

**What it does.** The ownership labels `platform.example.org/team`, `owner`, `cost-center` and `data-classification` come
only from your team definition, `platform/tenancy/teams/<team>.yaml` (ADR-0007, D-017, D-028).

- `derive-labels-<team>` and `derive-labels-pods-<team>` (MutatingPolicy) **add** the labels when they're absent. They
  cover Deployments, StatefulSets, DaemonSets, Jobs, CronJobs, Services, ServiceAccounts, PVCs, HTTPRoutes,
  ExternalSecrets, XRs and pod templates.
- `ownership-labels-<team>` (ValidatingPolicy) **rejects** an object that sets one of them to a different value.

**Why.** Cost allocation, paging and ownership reports group by these labels. If a manifest could set them, a report
could be wrong without anyone noticing.

**Fix.** Remove the labels from your manifests and values; the platform adds them. To change your team's owner or cost
center, change your team definition by PR (journey O1).

**Tests.** `platform/policies/tests/ownership-labels/` covers no labels (pass, and the mutation adds them), matching labels
(pass) and an overridden cost center (fail).
