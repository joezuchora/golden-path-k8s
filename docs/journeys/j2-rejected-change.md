# J2 A rejected change tells you how to fix it

**Who:** an app team. **Promise:** P4 ("A rejected change tells you how to fix it", F16). **Exit criterion 4.**
**Suite:** `tests/e2e/j2-rejected-change/`.

## What the developer does

Merges a PR that the platform must refuse. The suite merges two:

| Case | Change | Denied by |
|---|---|---|
| (a) image | `image:` points at the same app pushed **without** the platform signature (the `UNSIGNED` CI fixture) | `image-admission-team-a` (ImageValidatingPolicy) |
| (b) manifest | a raw Deployment committed into `xrs/dev/`, which syncs into the tenant namespace (XRs only) | `tenant-namespace-xrs-only` (ValidatingPolicy) |

## What the developer sees

The merge commit gets a **failure** commit status from `platform/argocd/<application>`. Its description is the Kyverno
denial, which always has four parts (ADR-0012):

> **what failed** (policy and object) · **Why:** the reason the rule exists · **Fix:** the change to make in the PR ·
> **Docs:** a link to `docs/policies/<policy>.md`

The suite asserts all four parts in each status and that nothing was admitted. The same message appears on the Argo CD
application. The fix is another PR; no one needs cluster access.

Manifest mistakes inside golden-service values (for example a `team` or `tags` field, or a missing memory limit) are
caught earlier, by the chart's `values.schema.json` (D-062), before admission.

## Where kind deviates

None in the denial path: the policies, messages and notification template are the ones AKS uses. Only the Git host
differs (D-043).

**Stated gap:** a denied create leaves no object, so there's no `PolicyReport` entry for it. PolicyReports record
background results for objects that exist (contract P3). The denial itself is recorded by the commit status and Argo CD.
