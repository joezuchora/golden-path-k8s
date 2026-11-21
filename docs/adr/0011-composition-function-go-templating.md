# ADR-0011: Composition function: function-go-templating

- **Status:** Accepted (2026-11-21: every fitness check passed; render golden files and schema validation in `make validate`, derived tags live in J4)
- **Date:** 2026-11-20
- **Contract promise:** P1 A place to run
- **CNCF capability domain(s):** APIs for automatically provisioning capabilities; Data services
- **Related decisions:** D-044, D-024, D-017, D-053

## Context
Crossplane v2 removes native patch-and-transform, so every composition is a function pipeline (F4). Each XRD needs an
`azure` and a `local` composition (ADR-0002), and every composed Azure resource must carry tags derived from the XR's
Namespace labels, never from XR fields (D-017, ADR-0007). So the function must read a Namespace that isn't part of the XR.
Crossplane v2 calls that "required resources" (v1: "extra resources"); a function "can request any cluster-scoped or
namespaced resource Crossplane already has access to" (F27). XR connection details are gone in v2; the recommended pattern
is a composed `Secret` (F27). Both candidates render offline with `crossplane composition render`, which needs Docker (F26).

## Decision drivers
- Readable by the platform team and by reviewers of a public reference repo.
- Reads the XR's Namespace for derived tags.
- Testable offline in `make validate` and CI.
- Few moving parts (no extra function only to fetch the Namespace).

## Options considered
| Option | Pros | Cons | Cost / operational load |
|---|---|---|---|
| **AKS-native:** ASO resources behind kro | Microsoft-supported Azure coverage | kro is "still pre-1.0" (F17); no `local` backend for kind | No function to run; a second abstraction model |
| **function-go-templating** v0.13.2 | Same Helm-style templates as `charts/golden-service`; built-in `ExtraResources`; readiness by annotation; ADR-0002 already assumed it | Untyped; template injection unless values go through `quote`/`toJson` (F27); the README documents only the v1 "ExtraResources" name | One function package |
| function-kcl v0.12.3 | Typed schemas; documents v2 `requiredResources` explicitly | A new language for the team and readers; older last release | One function package |
| function-go-templating + function-extra-resources | The pattern ADR-0007 first sketched | A second function only for a lookup go-templating already does | Two function packages |

## Decision
Use function-go-templating (v0.13.2) plus function-auto-ready (v0.7.3) for every composition. Read the XR's Namespace with
go-templating's built-in `ExtraResources`; `function-extra-resources` isn't used. All string values pass through `quote` or
`toJson`. The composed connection `Secret` is an explicit resource in the template.

**Gate:** before the first XRD, spike S1 proves on Crossplane 2.4.3 that the Namespace's labels reach the template, both in
`crossplane composition render` (with the Namespace as an extra-resource input) and on a live kind cluster. If it fails,
this ADR is revisited in favor of function-kcl.

**Spike S1 result (2026-11-20, F36).** Passed offline: with `apiVersion: meta.gotemplating.fn.crossplane.io/v1alpha1`,
`kind: ExtraResources`, the Namespace arrives as `.extraResources.<key>.items[].resource` and its labels are readable. The
first pass has no extra resources, so the templates guard for an empty list. The live check runs in J4.

## Consequences
- Positive: one templating language across the chart and the compositions; golden-file render tests in `make validate`.
- Negative / accepted trade-offs: no type checking inside templates, so the XRD's OpenAPI schema and the render tests carry
  that load; escaping is a review rule.
- Escape hatch: a composition whose logic outgrows templates can use function-kcl in its own pipeline; the XRD API doesn't change.

## Fitness check
- `make validate`: `crossplane composition render` for each composition against example XRs, with the Namespace supplied as
  an extra resource, compared to golden files; the output must contain every required tag with the Namespace's values.
- `crossplane resource validate` of the rendered output against the pinned provider and CloudNativePG CRDs.
- J4 e2e on kind: the composed resources carry the derived labels and tags.
