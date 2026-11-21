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

## 2026-11-20: Phase 3 re-verification and the pin rule (D-027 → D-039, D-040, D-041)

Before Phase 3 built anything on F3–F15, every one was fetched again from its primary source. Eleven held. The rest moved:

| Finding | What the log said | What the source says now | Change |
|---|---|---|---|
| Gateway API pins | Gateway API v1.6.1, Envoy Gateway v1.9.0, Cilium v1.20.0, as installable pins (D-027) | Cilium 1.20 "must" have the Gateway API **v1.6.3** CRDs (F30); v1.6.3 and v1.7.0 now exist (F14) | The conformance basis (v1.6.1 / v1.9.0 / v1.20.0) is kept as the contract's evidence; the installed versions are the newest eligible patches (≥14 days old), and the network-contract suite re-proves the features on them (D-039) |
| Kyverno policy API | Admission designed on `ClusterPolicy` `verifyImages` (ADR-0005) | `ClusterPolicy` is deprecated in 1.19 and **not executed** in 1.20 (F24) | Policy set v1 moves to the CEL policy types before a single policy is written (D-042, ADR-0012) |
| Crossplane CLI | `crossplane beta validate` | v2.4 has `crossplane resource validate` and `crossplane composition render` (F26) | Commands corrected (D-040) |
| Quotes | F4, F10, F13 quoted phrases the sources no longer contain, or attributed them to the wrong page | See F4, F10, F13 | Text corrected (D-041) |

**Why it matters.** The design said "pin what the contract depends on". The re-check showed what that means in practice: a
pin set can be internally inconsistent (Cilium 1.20 can't run on the v1.6.1 CRDs), and a policy engine can drop the API a
design was written against between two minor releases. Separating the *evidence* a pin rests on from the *patch* that is
installed keeps the contract honest without freezing security fixes.

**Lesson.** Re-verifying cost an hour and changed the policy engine's API before any code depended on it. Done after the
build, the same finding would have been a rewrite of the whole policy set.

## 2026-11-20: Phase 3 planning decisions (D-012 → D-046, D-026 → D-042, D-043 to D-053)

**Placeholder coordinates retired (D-012 → D-046).** Phase 1 kept the repo coordinates as `<org>/golden-path-k8s` because the
publishing owner wasn't decided. Phase 3 signs real images, and the admission policy binds the signer and the caller repo
(D-026), so a placeholder can't be tested. The coordinates become `joezuchora/golden-path-k8s`, from one file, and the repo is
made public. Planning also found the repo was still private, which would have broken D-031's premise (free GHCR, anonymous
pulls) and put the kind stack on 8 GB CI runners (F28, F29).

**Admission mechanism moved, binding unchanged (D-026 → D-042).** The three-way binding (signer + caller + base digest) and
fail-closed behavior stand. The API changes from `ClusterPolicy` `verifyImages` to `ImageValidatingPolicy`, because Kyverno
1.20 no longer executes `ClusterPolicy` (F24). ADR-0012 records the gate: prove the binding and offline `kyverno test` before
writing the policy set.

**Choices made with the owner.** Composition function: function-go-templating, gated by a Namespace-read spike (D-044,
ADR-0011). Git host for kind journeys: in-cluster Gitea, so "a rejected change gives Git feedback" is tested against a real
commit-status API (D-043). Journeys: J1–J4 plus O1 (D-052). The minimum CI (build-sign workflow and a PR check) moves from
Phase 6 into Phase 3, because exit criterion 3 needs a CI-signed image (D-047).

## Open questions about platform fit

The [four-role platform review](platform-review.md) records gaps raised from development, infrastructure,
QA, and security perspectives.

The [Developer Contract v1](developer-contract.md) starts with a containerized service on AKS. The four
promises give us a way to evaluate other workloads and enterprise requirements. These questions record
where we may need an extension, an integration with a capability another team operates, or a separate
supported path.

### Hybrid and hub-and-spoke networking

Could the platform run in an existing enterprise hub-and-spoke network, including multiple regions or
subscriptions and private connections to on-premises systems? The current network contract describes
application routing and isolation inside the workload environment. An organization may already own transit
routing, firewalls, address space, and DNS. The question is where that ownership ends and where platform
self-service begins. A concrete case is a team requesting private access to an on-premises dependency
with approved DNS, controlled egress, and a clear way to diagnose failures across that boundary.

### GPU inference and training

Long-running inference endpoints may fit parts of the service path, including HTTPS, identity, rollout,
and diagnostics. What extra guarantees would teams need around GPU quota, capacity, scaling, model artifacts,
and cost? Training has a different lifecycle. It needs a way to queue and run jobs, access data, resume
from checkpoints, and release capacity. Which workloads could use an optional AKS profile, and which
would be better served by an existing ML platform? In either case, who owns failures and how does the team
see its run status and costs?

### Serverless, microVMs, and other runtimes

What should a team do when it needs event-driven serverless execution, a microVM isolation boundary, or
a VM-based runtime? Could it request an approved runtime and keep a familiar path for ownership, identity,
release and rollback, diagnostics, and support? Where a runtime cannot provide a promise, the team needs
to see the limitation and the supported route before choosing it.

### GitHub organization and repository governance

Treat GitHub organization setup as a platform design question. The current design covers a reusable
build/sign workflow (D-047), admission's trust in the workflow and caller (D-055), and Renovate base-image
updates (D-019). What should an organization require for new and existing repositories? Capture the
baseline for repo and project settings, access and ownership, branch and merge rules, required checks,
workflow permissions, approved actions, and Renovate presets and ownership. Separate the defaults that
templates scaffold from standards enforced by organization or repository settings, and ask how drift and
approved exceptions would be handled.

### Greenfield and brownfield adoption

Can a new team start with the platform defaults while an existing team adopts the same contract in
stages? An existing organization may already have clusters, networks, identity, repositories, CI/CD,
and running workloads with established owners. Which assets can the platform reference in place, which
can it take over with an explicit ownership handoff, and which require migration or an exception?
How would teams assess gaps before enforcement, preserve existing access and deployment paths during
adoption, and back out of a cutover if it fails? A concrete case is onboarding an existing service and
repo while retaining its private network and determining which release checks already meet the contract.

For each case, the useful answer is what a team can request, which of the four promises it gets, who
operates and supports it, and where it should go when the platform cannot meet the need.

## 2026-11-21: Phase 3 build findings and owner review (D-057 to D-068)

Building the kind platform turned several assumptions into measurements, and some of them were wrong.

- **Cilium on Docker Desktop (D-057, F40).** eBPF masquerading broke pod DNS through Docker Desktop's resolver, so kind
  runs iptables masquerading. The repo still cites eBPF host routing as a documented Cilium capability (D-018), but it is
  now a `byo` property; kind shows kube-proxy replacement and socket-LB only.
- **Direct Chainguard deploys (ADR-0005 narrowed by D-058).** The planned `chainguard-images` policy couldn't have an
  honest fail case, and a directly deployed image would skip the caller and base binding of D-026. App namespaces now
  admit only pipeline-built images; the Chainguard base is checked inside them.
- **Cosign format (D-059, F41).** cosign v3 writes a new bundle format by default, and a legacy attestation without a Rekor
  entry failed verification on the pinned Kyverno. CI signs in the legacy format with Rekor and checks every image against
  the rendered policy before any cluster sees it.
- **Policy scope (D-063).** App policies first excluded the CloudNativePG operator by requester; job pods created by the
  job controller showed that was too narrow. App policies now select app namespaces, and tenant namespaces get
  `tenant-namespace-xrs-only`, keyed on Argo CD's own tracking annotation.
- **XR deletion (D-061).** A per-directory XR application disappeared with its last file, so nothing was pruned. It is now
  generated per env from the team definition.

The owner's review of the working tree found twelve issues; each was reproduced or checked against its source before the
fix, and none were dismissed:

- **GHCR visibility (F29 corrected by F43, D-046 rationale corrected by D-065).** A public repo doesn't make its packages
  public. GitHub's own pages disagree, so the package admin sets visibility explicitly and `make doctor PROFILE=github`
  proves an anonymous pull of the exact digests.
- **What the bootstrap publishes (D-066).** It published untracked files to a repo anything in the cluster can read. It now
  publishes the index only, and seeding is idempotent (the review was right: 31 duplicate webhooks had accumulated).
- **Git feedback after a recovery (D-067).** Deduplicating on the revision hid a Healthy → Degraded → Healthy recovery.
  Fixing it exposed two more bugs that silently disabled every notification: Argo CD parses templates and triggers as YAML
  before rendering them (F45). `make validate` now parses them the same way, and live delivery to Gitea is proven.
- **kind targeting and the toolchain (D-068).** The suites can no longer reach another cluster; the Gateway pool comes from
  the real kind subnet; a cached CLI is bound to its lock entry and digest; the upgrade procedure keeps overrides in
  effect and locks all five platforms.

## 2026-11-21: First full journey runs (D-073, D-074)

The first run of every suite against a CI-signed image failed in five places, and each was a design or test gap rather
than flakiness. `require-controller` denied Deployments, because Kyverno autogenerates pod policies onto controllers by
default and a pod template has no owner; its tests used only Pods, so they couldn't see it. Deleting a team's last XR
never pruned it, because Argo CD's automated sync won't empty an application without `allowEmpty` (F47). Argo CD's own
values are bootstrap-owned, so a changed notification template never reached the cluster through Gitea. Git Bash rewrote
a pod-side path before `kubectl exec` passed it on. And J4 looked for a restart in the wrong field, since Reloader
changes the pod template's environment, not its annotations. All five were fixed at the cause, and `make e2e-all` then
passed all seven suites in one run. Its measured memory peak (5.97 GiB, F49) replaced the provisional 10 GiB requirement
with 8 GiB (D-074).

The run also settled two questions: the keyless-signed image passed the real admission policy in CI (the cosign format
concern in F41), and the new GHCR packages could be pulled anonymously without a settings change (F48), though the
doctor keeps checking that outcome.

## 2026-11-21: Phase 4, slice 1 (D-072 → D-079, D-078 to D-087)

Phase 3 placed every team app on every workload cluster and named its Application `<team>-<app>-<env>`, which was
correct for one spoke and a collision for two (D-072). Before AKS adds a spoke, the owner chose explicit assignment by
workload group in the team definition and cluster-suffixed names (D-079). The rename happens now, while only kind
clusters exist; the placement suite proves both halves (an ungrouped cluster gets no team apps, a second cluster in the
group gets a second Application).

The split topology needed answers Phase 3 deferred. External Secrets now also runs on a control-only cluster, guarded so
kind keeps one install (D-078), and per-environment IDs reach the charts through the cluster Secret, the same carrier the
profile already used (D-081). Reading the azure composition against the pinned provider turned up a key mismatch that no
Phase 3 test could catch (the pushed key `<namespace>-<name>` vs. the `<name>` golden-service reads), fixed with the move
to the tenant resource group and VNet integration (D-082). The Workload Identity paths for Argo CD and ESO, and the
absence of a documented whole-Secret PushSecret for Key Vault, were checked against their primary docs first (F55, F56).

Nothing in this slice has run on Azure. The tracker in the Decision Log keeps local evidence and live evidence apart, and
`infra/aks/aks.sh` refuses to apply until the subscription is confirmed (D-083 to D-087).

## 2026-11-21: Terraform for AKS foundations (D-013 → D-088)

D-013 chose OpenTofu for its license and kept the HCL Terraform-compatible. The owner selected HashiCorp Terraform for the
reference implementation. A first draft of that decision, made in a separate session, was never merged and reused D-073,
a number `main` had already taken, so slice 1 was built on OpenTofu and the conflict surfaced in review. Because the HCL
had stayed compatible, switching the engine before merge changed only the toolchain pin, the provider lock (now from
registry.terraform.io), the scripts that call the CLI, and the records ([ADR-0009](adr/0009-terraform-for-aks-foundations.md)).
The license is stated, not assumed: Terraform 1.6.0 and later are under the Business Source License (F58).

