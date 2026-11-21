# Maturity self-assessment

**Assessed:** 2026-11-20, at the Phase 2 exit. **Method (D-034):** a *current* level is claimed only with linked evidence. A
*designed target* is the level the design aims for once Phases 3–6 exit, and it states what will prove it. Both models
are reassessed at every phase exit.

**Honest summary.** Today this is a design and a contract: no platform runs, and there are no users. So every aspect is at
the **lowest level of both models**. The design targets the middle levels on purpose. The CNCF model says "reaching the
highest level should not be a goal in itself", and that "each aspect is meant to be evaluated and evolved independently" (F19).

A reference repo can't by itself demonstrate organizational aspects (investment, adoption). For those, the target
describes what the design *assumes* of an adopting organization, not something this repo can prove.

## CNCF Platform Engineering Maturity Model (5 aspects × 4 levels, F19)

Levels: 1 Provisional · 2 Operational (headed "Operationalized" in the model's detail sections) · 3 Scalable · 4 Optimizing.

| Aspect | Current | Evidence | Designed target | Proven by | Why not higher |
|---|---|---|---|---|---|
| Investment | **1 Provisional**: Voluntary or temporary | A single maintainer's reference project; no funded team | 2 Operational: Dedicated team (assumed of an adopter) | Not provable by a repo. The [RACI](../developer-contract.md#raci-d-037) assumes a dedicated platform on-call | Level 3 (As product) needs product management and UX investment, which is organizational |
| Adoption | **1 Provisional**: Erratic | No users yet | 3 Scalable: Intrinsic pull | The adoption metric (`contract-version` label share) and the satisfaction survey (D-038), in an adopting org | Level 4 (Participatory) needs users contributing back; not designed for in v1 |
| Interfaces | **1 Provisional**: Custom processes | Nothing runs yet; there are only docs | 3 Scalable: Self-service solutions | Phase 3/5 journeys: a Backstage template → deployed app; an XR → a usable database, with no ticket and no `cluster-admin` | Level 4 (Integrated services) needs capabilities embedded in teams' existing tools and provisioned automatically |
| Operations | **1 Provisional**: By request | No platform components are operated yet | 3 Scalable: Centrally enabled | Standard upgrade and deprecation process (ADR-0010); the platform on-call owns components (D-037); CI-gated Renovate bumps (D-019) | Level 4 (Managed services) needs capability updates delivered continuously without user impact. The RACI is the "shared responsibility model" Level 4 describes, but upgrade automation isn't proven |
| Measurement | **1 Provisional**: Ad hoc | Metrics are defined with sources, but nothing is collected yet (D-038) | 2 Operational: Consistent collection | Phase 6 baselines for DORA, time to first deploy and adoption; a fixed-question survey | Level 3 (Insights) needs organization-wide alignment on success measures and a dedicated owner |

## Microsoft platform engineering capability model (6 capabilities × 5 stages, F20)

Stages: Initial · Repeatable · Defined · Managed · Optimized (the full-chart PDF labels the last stage "Optimizing"). Microsoft
says the capabilities "closely align" with the CNCF model (F20). Governance is the capability the CNCF model doesn't have as
an aspect (F9).

| Capability | Current | Evidence | Designed target | Proven by | Why not higher |
|---|---|---|---|---|---|
| Investment | **Initial**: Voluntary | As for CNCF Investment | Defined: Operationalized with a dedicated team (assumed of an adopter) | Not provable by a repo | Managed (Scalable as a product) is organizational |
| Adoption | **Initial**: Informal | No users | Managed: Value-driven | Adoption and satisfaction metrics (D-038) in an adopting org | Optimized (Participatory) needs a contributor ecosystem |
| Governance | **Initial**: Independent | Policy is *designed* in ADR-0005/0006/0007, but no policy is enforced yet | Managed: Integrated | Kyverno admission (`kyverno test` pass/fail cases), Azure Policy tag compliance, fail-closed image verification (D-026), cost by `team` (ADR-0007) | Optimized (Predictive) needs predictive analytics on risk; out of scope |
| Provisioning and management | **Initial**: Manual | No compositions exist yet | Managed: Automated | XR lifecycle e2e (create, connect, rotate, delete) through GitOps (D-024) | Optimized (Adaptive) needs intelligent, proactive resource management |
| Interfaces | **Initial**: Custom processes | Docs only | Managed: Self-service solutions | Backstage template and XR journeys (Phases 3 and 5) | Optimized (Integrated services) as for CNCF Interfaces level 4 |
| Measurement and feedback | **Initial**: Ad hoc | Metrics are defined, not collected (D-038) | Defined: Consistent | Phase 6 baselines; a fixed-question survey | Managed (Insights) needs value-centric measures tied to business outcomes |

## How the two models map here

| CNCF aspect | Microsoft capability | Note |
|---|---|---|
| Investment | Investment | Same subject, different scales: 4 levels vs. 5 stages |
| Adoption | Adoption | — |
| Interfaces | Interfaces | The stage names overlap (Custom processes, Standard tooling, Self-service solutions, Integrated services) |
| Operations | Provisioning and management | Closest match. This repo's evidence for both is the XR lifecycle and the upgrade process |
| Measurement | Measurement and feedback | — |
| — | Governance | The policy set, tagging taxonomy and admission binding are this repo's governance evidence |

The two scales don't convert into each other, so each model is scored on its own terms. No level is averaged or combined.

## Next reassessment

At the Phase 3 exit. That is the first point where *current* can move. For example, Interfaces and Provisioning and management
could move up once the kind journeys pass.
