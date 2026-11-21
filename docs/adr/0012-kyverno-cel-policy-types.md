# ADR-0012: Kyverno policy set v1 on the CEL policy types

- **Status:** Proposed
- **Date:** 2026-11-20
- **Contract promise:** P4 A safe way to ship
- **CNCF capability domain(s):** Security services
- **Related decisions:** D-042, D-055, D-026 (Revisited), D-008 (Revisited), D-036, D-058, D-059, D-063

## Context
The Kyverno policy set is part of the contract v1 surface (D-014). ADR-0005 designed admission on `ClusterPolicy`
`verifyImages`. Re-verification for Phase 3 (F24) found that `ClusterPolicy` is "Deprecated (v1.19), removed in v1.20", and
that "Kyverno v1.20 no longer executes the deprecated `ClusterPolicy`, `Policy`, `CleanupPolicy`". Kyverno v1.20.0 was
released on 2026-11-12. The replacements (`ValidatingPolicy`, `ImageValidatingPolicy`, `MutatingPolicy`, and
`PolicyException` in `policies.kyverno.io`) are Stable in v1.19 (F24). `ImageValidatingPolicy` supports keyless identities,
in-toto attestations with CEL on the predicate, `mutateDigest` and `failurePolicy`; `ValidatingPolicy` supports
`messageExpression` and writes PolicyReports (F25). Whether `kyverno test` evaluates an `ImageValidatingPolicy` offline isn't
stated (F25).

## Decision drivers
- No contract break on the first Kyverno upgrade (D-036: an `Audit` → `Enforce` or binding change is a major).
- Keep the D-026 binding and fail-closed behavior exactly.
- Every policy keeps pass and fail `kyverno test` cases (CLAUDE.md invariant).
- Denial messages carry what, why, the fix and a docs link.

## Options considered
| Option | Pros | Cons | Cost / operational load |
|---|---|---|---|
| **AKS-native:** Deployment Safeguards + Ratify/Notation | Managed; the blog's path (F17) | Versions only Microsoft's policy set; Notation instead of Sigstore (ADR-0005) | Managed |
| `ClusterPolicy` on Kyverno 1.19 | Documented examples for `verifyImages` attestations | Not executed by 1.20 (F24): policy set v1 would break on the first upgrade | A forced rewrite within months |
| **CEL policy types on Kyverno 1.19.2, then 1.20.x** | Stable in 1.19; carried forward by 1.20; the same CEL model as Kubernetes admission policies | Fewer published examples; IVPOL offline testing unverified | Normal upgrades |
| sigstore policy-controller for images + Kyverno for the rest | Purpose-built image verification | Two admission engines and two message formats (ADR-0005) | Two components |

## Decision
Policy set v1 uses only `ValidatingPolicy`, `ImageValidatingPolicy`, `MutatingPolicy` and `policies.kyverno.io`
`PolicyException`. `make validate` fails on any `ClusterPolicy` or `Policy` manifest. Kyverno is pinned to v1.19.2 (chart
3.9.2) and moves to 1.20.x once it's 14 days old (D-039). Each policy sets `failurePolicy: Fail` explicitly. Every
validation in a `ValidatingPolicy` or `ImageValidatingPolicy` builds its denial with `message` or `messageExpression` in the
form *what failed · why · fix · docs link*, where the link goes to `docs/policies/<policy>.md`. A `MutatingPolicy` has no
message field (its schema in v1.19.2 has none); a mutation never denies, and the validating policy paired with it
(for example `ownership-labels-<team>` with `derive-labels-<team>`) carries the denial message (D-063).

**Gate (spike S2), before the policy set is written:** prove on Kyverno 1.19.2 that an `ImageValidatingPolicy` can (1) check
the keyless signer subject and issuer, (2) check the caller repository and ref from signed provenance, (3) check the
`base-image` predicate digest against the verified set, (4) read the target Namespace's team allowlist, and (5) be
evaluated by `kyverno test` with pass and fail cases. How the caller is bound (Fulcio's Source Repository extensions or a
SLSA provenance attestation) is recorded as its own D-entry after the spike. If (5) fails, the pass/fail invariant can't be
met for that policy, and the decision goes back to the owner before any workaround.

**Spike S2 result (2026-11-20, F35).** (1) signer subject/issuer: proven. (2) caller from signed provenance: proven
mechanism (`verifyAttestationSignatures` + `extractPayload(...).predicate`); the attestation format is fixed in D-055.
(3) base digest: same mechanism, on the `base-image` predicate. (4) team allowlist: rendered per team instead of read from
`namespaceObject` (D-055). (5) `kyverno test` pass and fail: proven, **online** (the registry and Rekor must be reachable),
so `make test-policies` needs network and a CI runner with internet access. A non-existent image is an evaluation error, so
fail cases use real images signed by another identity.

## Consequences
- Positive: the first Kyverno upgrade doesn't touch the contract; one CEL model for all admission logic.
- Negative / accepted trade-offs: fewer upstream examples; ADR-0005's wording (`verifyImages`, `attestations` conditions)
  describes the intent, and this ADR describes the mechanism.
- Escape hatch: a `policies.kyverno.io` `PolicyException` with an owner, a reason and an expiry (ADR-0005).

## Fitness check
- `make validate`: no `ClusterPolicy`/`Policy` kinds; every policy sets `failurePolicy: Fail`; every message names a
  `docs/policies/` page that exists.
- `make test-policies`: pass and fail cases for every policy, asserting the message text.
- J2 e2e on kind: a denied image and a denied manifest each surface the same message on the Gitea commit status and in a
  PolicyReport.
