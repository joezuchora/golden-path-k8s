# Design evolution

This page tells the story of how and why the design changed. Each entry links to the
[Decision Log](adr/README.md) entries it affects. Entries are only ever added, never rewritten.

## 2026-11-20: Managed Cilium can't run Cilium's Gateway API (D-004 → D-005)

**Original intent.** AKS with Azure CNI Powered by Cilium, using Cilium's built-in Envoy as the Gateway API controller and
Hubble for flow visibility. This was the same stack as the local kind cluster.

**What verification found.** The AKS documentation (updated 2026-08-24) says only label exclusion can be changed in the
managed Cilium ConfigMap. That rules out turning on Cilium's Gateway API. L7 and FQDN policy require the paid
Advanced Container Networking Services (ACNS) add-on. The AKS Engineering Blog post the repo builds on doesn't
mention Cilium at all.

**Options weighed.**
1. BYO OSS Cilium only. Full features, but Microsoft doesn't support the CNI, so this is exactly the "plumbing"
   the blog warns against owning.
2. Managed Cilium only. The most supportable option, but it drops a stated requirement and creates a gap between kind and AKS.
3. Dual mode.

**Decision.** Dual `cilium_mode = managed | byo`, with `managed` as the default. Apps depend only on `HTTPRoute` and
`CiliumNetworkPolicy`, so the Developer Contract is the same in both modes. Only the `GatewayClass` changes.

**Why it matters.** This is the repo's thesis in miniature: the contract stays fixed and the tools that fulfill
it can change. Envoy Gateway was then chosen as the managed-mode controller (D-006).

## 2026-11-20: Three requirements checked against primary sources (D-017, D-018, D-019)

**"eBPF sockmap acceleration" dropped (D-018).** The original brief claimed this as a Cilium benefit. Current Cilium
docs don't mention sockops or sockmap; they document socket-LB and eBPF host routing. A public reference repo
can't make performance claims it can't source, so the claim was replaced with the documented features.

**Ingress-NGINX is retired, not just "worse".** The comparison in ADR-0003 originally rested on performance and operational
simplicity. Checking showed the project was archived on 2026-03-24 with no further security fixes. That makes
Gateway API a necessity rather than a preference, which is a stronger argument.

**Chainguard free tier is `:latest` only (D-019).** Anonymous registry probes confirmed that every base image the templates
need is free at `:latest`/`:latest-dev`, and that versioned tags are not. Python or .NET majors can't be pinned for free,
so reproducibility comes from digest pinning plus CI-gated Renovate PRs, and the paid tier is the upgrade path.

**Tag values derived, not entered (D-017).** A plan review asked how team/cost-center tags travel from Backstage to
Crossplane and OpenCost. The answer moved the source of truth out of Backstage: the team definition owns the
FinOps keys, and Backstage supplies only `app` and `env`. If developers type cost-center into a form, the values
drift and can be spoofed; deriving them makes cost reports trustworthy.

## 2026-11-20: External review (D-020 to D-028)

An independent review of the Decision Log and ADRs found six gaps. Every upstream claim it made was checked
against the primary docs before anything changed (F11–F15). None were refuted, and three were confirmed only in part,
which refined the fixes. What changed, and why:

| Gap the review found | What was wrong | Fix |
|---|---|---|
| App identity undefined | Workload Identity appeared only in ESO's secret sync. Promise 2 ("An identity") had no app-level design | New ADR-0008: per-app UAMI federated to the app's ServiceAccount, platform-created, with allow/deny tests as an AKS release gate (D-022) |
| Tenant isolation by UI filter | "Filtered by catalog ownership" isn't authorization. Grafana viewers can query any data source in their org; Backstage's serviceAccount mode gives everyone the same access | Enforcement at each backend plus a cross-tenant deny test per backend (D-025) |
| Argo CD placement | One `role` key can't hold both values, and the in-cluster target has no Secret to label | Capability labels on declarative cluster Secrets; isolation check scoped to split AKS (D-023) |
| Crossplane fallback | A namespaced XR can't compose cluster-scoped resources, so the `LegacyCluster` fallback never worked | Namespaced MRs only. They already exist in the provider source. "Ready" now means the app connects, survives rotation and cleans up (D-024) |
| Admission binding | Pinning the reusable workflow proves *how* an image was built, not *for whom*; a `cgr.dev/` prefix doesn't prove the base | Bind the caller repo/ref and the exact base digest; fail closed explicitly (D-026) |
| Network "parity" | "Both use Envoy" was an inference, not a test | Pinned versions, an explicit v1 feature set, and one suite run per profile (D-027) |

**Where verification sharpened the review.** The review suggested checking the caller through Kyverno certificate
extensions. Kyverno documents only the GitHub-specific extension fields, and Fulcio has deprecated those OIDs. So the
caller is checked through a signed provenance attestation instead.

**What was declined.** The review also proposed resequencing: a thin first milestone, with Backstage, BYO Cilium, WAF and
OpenCost deferred. That was declined in favor of the original phase plan (D-020), because the complete platform is the
deliverable. Instead, the review's release gates became explicit phase exit criteria in the Decision Log. L7/FQDN
policy became an optional add-on (D-021), so the v1 baseline is provable at no cost.

**Lesson.** Four of the six gaps were cases where the design *read* correctly but would have *failed*: a placement scheme
that couldn't match, a fallback that couldn't compose, isolation that wasn't enforced, and a signature check any repo
could pass. Each now has a fitness check that would have caught it.

## 2026-11-20: Phase 2 source verification (D-029 to D-035)

Before writing the README and the contract, every source was fetched again in full (F16–F22). Reading the blog's
promise tables row by row changed how the network path is attributed, and the Phase 1 docs had misread or misquoted
several sources.

| Finding | What Phase 1 said | What the source says | Change |
|---|---|---|---|
| HTTPS URL | The network path was "this repo's extension" under P2 | The blog lists "Your app gets an HTTPS URL" under **An identity**, and network policy under **A place to run** ("own boundary") (F16) | Gateway, cert-manager and ExternalDNS → P2; CNI and `CiliumNetworkPolicy` → P1. Only Cilium as the dataplane, the WAF and the L7/FQDN profile are extensions (D-029) |
| Blog quote | "the contract is portable while the defaults are not" | "The contract is portable, the defaults aren't." (F17) | Quote corrected (D-030) |
| "Not built in" | The blog lists Crossplane and kro as "Not built in" | "Not built in" is the **On AKS** cell of the row "You can request an environment"; Crossplane and kro are in the bring-your-own column (F16) | ADR-0002 corrected (D-030) |
| CNCF domain names | Shortened names (e.g. "Identity and secret management services", "Observability") | The table names, e.g. "Identity and secret services", "Application observability" (F18) | Every ADR header uses the table names, and `verify-docs.sh` enforces them (D-030, D-035) |
| AKS Automatic CNI | "Managed Cilium only" | Azure CNI Overlay powered by Cilium is the *default*; "Bring your own CNI" is listed only for Standard (F23) | ADR-0001 narrowed to what the docs state (D-030). The conclusion holds: `byo` needs Standard |
| Maturity levels | Not used yet | CNCF: 4 levels; Microsoft: **5** stages, with different names (F19, F20) | The self-assessment scores each model on its own scale (D-034) |

**Gaps made explicit rather than left implicit.** Building the contract matrix showed that no decision named the image
registry, so GHCR was chosen with ACR as the AKS-native alternative (D-031). The blog's row "A bad release doesn't reach
everyone" has no v1 answer, so automated progressive delivery is recorded as out of v1 (D-032). Two CNCF domains are deferred
with reasons (D-033).

**Cross-reference added by the new check.** The external-review entry above describes three reversals without naming the
original decisions. For the record: D-003 → D-024 (Crossplane fallback), D-008 → D-026 (admission binding), and D-009 →
D-025 (tenant isolation). `verify-docs.sh` now requires every revisited decision to appear in this file.

**Lesson.** A summary of a source drifts from the source. The Phase 1 attributions were close but not exact. In a public
reference repo, "close" is how a reviewer finds the first crack. Now every citation must resolve to an F-entry, and a
script checks it (D-035).
