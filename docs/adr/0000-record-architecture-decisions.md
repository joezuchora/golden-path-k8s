# ADR-0000: Record architecture decisions; Developer Contract as the organizing principle

- **Status:** Proposed
- **Date:** 2026-11-20
- **Contract promise:** All
- **CNCF capability domain(s):** All (this ADR sets how they are mapped)
- **Related decisions:** D-001, D-015, D-030

## Context
This repository is a public reference IDP. Readers judge it by the reasoning behind its choices as much as
by the code. Three industry sources agree on how to approach a platform:

- **CNCF Platforms White Paper**: a platform is "an integrated collection of capabilities defined and
  presented according to the needs of the platform's users". It lists 7 attributes (platform as a product,
  user experience, documentation and onboarding, self-service, reduced cognitive load for users, optional and
  composable, secure by default) and 13 capability domains (F18).
- **CNCF Platform Engineering Maturity Model**: 5 aspects (Investment, Adoption, Interfaces,
  Operations, Measurement) × 4 levels (Provisional, Operational, Scalable, Optimizing) (F19).
- **Microsoft Learn, platform engineering**: a product mindset, paved and golden paths, a "thinnest viable
  platform", and no "big bang approach" (F21); a 6-capability model that adds governance (F9, F20).
- **AKS Engineering Blog, "Build the platform, not the plumbing, on AKS"** (2026-11-09): "tools
  shouldn't dictate your developer contract; they should fulfill it". It sets out 4 promises, the BACK
  stack, and a control/workload cluster split (F2, F16, F17).

## Decision drivers
- A stable organizing spine that survives tool changes.
- Accurate attribution of each idea to its source.
- Decisions, and reversed decisions, that can be audited.

## Options considered
| Option | Pros | Cons |
|---|---|---|
| **AKS-native:** adopt AKS Automatic's opinionated defaults as the contract | Least to run | The contract becomes whatever the product's defaults are; not portable (the blog: "The contract is portable, the defaults aren't." F17) |
| Tool-first (organize by component) | Familiar | Hides why each tool exists; nothing to measure against |
| CNCF capability list as the spine | Neutral and comprehensive | Has no app-team-facing promises and no ownership model |
| **Contract-first, framework-measured** | Developer-facing, versionable, measurable against CNCF and Microsoft models | Needs discipline to keep the mapping current |

## Decision
1. The versioned **Developer Contract** (4 promises, from the AKS blog) is the README spine. Each component maps to a
   promise and to one or more CNCF capability domains. `docs/frameworks/` publishes the coverage map and a maturity
   self-assessment against the CNCF and Microsoft models.
2. Decisions are logged at two levels in [README.md](README.md): a D-entry for every decision, plus an ADR when a
   decision changes which tool delivers a promise, crosses a security boundary, or is costly to reverse.
3. Reversed decisions are never deleted. They are marked `Revisited → D-xxx` and explained in
   [design-evolution.md](../design-evolution.md).
4. Cilium, Chainguard and Cosign are presented as this repo's extensions, not as the blog's recommendations (F1).

## Consequences
- Positive: every choice can be traced back to a promise and a source, and the design history stays visible.
- Negative: two places to update (the README matrix and the framework map) whenever a component changes.

## Fitness check
`scripts/verify-docs.sh` (D-035) is the gate from Phase 2 onward. It grows into a CI job (`decision-log-check`,
Phase 6), which fails when an ADR file is missing from the index, an index link
points to a missing file, or an ADR lacks a required section or an AKS-native option.
