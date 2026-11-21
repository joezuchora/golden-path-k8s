# ADR-0010: Contract versioning via a single versioned surface

- **Status:** Proposed
- **Date:** 2026-11-20
- **Contract promise:** All
- **CNCF capability domain(s):** Golden path templates and docs; APIs for automatically provisioning capabilities; Security services
- **Related decisions:** D-014, D-036, D-028

## Context
The Developer Contract is the spine of this repo (ADR-0000). The blog advises teams to "Pin what your contract depends on,
such as your template and module versions" and notes that "The contract is portable, the defaults aren't." (F17). App teams
need to know what a change to the platform will break. Four artifacts make up what an app team consumes (D-014):

| Surface | Versioned as |
|---|---|
| `charts/golden-service` | Helm chart semver, 1.x for contract v1 |
| Crossplane XRDs (`platform.example.org`) | API version `v1` for contract v1 |
| `.github/workflows/reusable-build-sign.yaml` | Git tag `@v1` |
| Kyverno policy set | Policy set v1 (labelled on each policy) |

If each artifact versioned independently, an app team would have to track four compatibility matrices.

## Decision drivers
- App teams depend on one number.
- A breaking change is visible before it is enforced.
- The platform team can measure who is still on an old version.

## Options considered
| Option | Pros | Cons |
|---|---|---|
| **AKS-native:** rely on Deployment Safeguards and AKS release versioning | Managed | Versions only Microsoft's own policy set and the cluster, not the platform's app-facing API |
| Per-template charts, each versioned separately | Teams can move independently | N compatibility matrices; no single statement of what "v1" guarantees |
| No versioning (main is the contract) | Least process | Breaking changes reach teams without warning |
| **One contract version over the four surfaces** | One number; enforceable; measurable through the `contract-version` label | Release coordination across four artifacts |

## Decision
The contract is versioned as a whole with semver (D-036):
- **Minor (v1.x):** additive only, such as new optional chart values, new optional XRD fields, or new policies in `Audit` mode.
- **Major (v2):** any removal, any renamed or now-required field, any policy moving from `Audit` to `Enforce` that rejects
  previously valid manifests, and any change to the admission binding. A major needs an ADR, a migration guide in
  `docs/`, and a new XRD API version that is served alongside the old one.
- **Deprecation:** announced in the contract's changelog at least one minor release before removal. A deprecated
  behavior runs as a Kyverno `Audit` warning, so it shows up in the team's `PolicyReport` and Backstage tab, before it is
  enforced.
- **Support window:** the current and previous major are supported at the same time.
- **Adoption signal:** every app object carries `platform.example.org/contract-version` (ADR-0007). The share of services
  per version is the adoption metric (D-038).

## Consequences
- Positive: one guarantee to read; breaking changes arrive as warnings first; adoption per version can be measured.
- Negative: chart, XRD, workflow and policy releases must be coordinated; two majors at once means two sets of e2e tests.
- Escape hatch: a team that can't migrate within the window requests a time-boxed exception through a PR, with an owner and expiry date.

## Fitness check
Phase 6 CI: a change to any of the four surfaces that removes or renames a field, or makes an `Audit` policy `Enforce`,
fails unless the contract major version is bumped and a migration guide exists. Until then, `scripts/verify-docs.sh` checks that
`docs/developer-contract.md` states the version and the surface.
