# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose
Public, production-grade reference Internal Developer Platform on AKS. The versioned Developer Contract
(`docs/developer-contract.md`, 4 promises) is the spine. It is grounded in the CNCF Platforms White Paper
and Platform Engineering Maturity Model, Microsoft Learn's platform engineering guidance, and the AKS
Engineering Blog post "Build the platform, not the plumbing, on AKS" (Paul Yu, 2026-11-09,
https://blog.aks.azure.com/2026/11/09/build-the-platform-not-the-plumbing). Tools fulfill the contract;
they never define it. Cite each source only for what it actually says.

## Decision tracking (mandatory)
- `docs/adr/README.md` is the Decision Log. Any change that makes or alters a design decision must add or
  update its D-entry in the same change: date, options, rationale, AKS-native alternative, status.
- Write an ADR (`docs/adr/NNNN-*.md`, from `template.md`) when a decision changes which tool delivers a
  contract promise, crosses a security boundary, or is costly to reverse.
- Never delete a reversed decision. Mark it `Revisited → D-xxx`, and add a paragraph to
  `docs/design-evolution.md`.
- After logging a decision, also update the private notes at
  `C:\Users\joezu\Documents\golden-path-k8s-notes\talking-points.md` (outside the repo; never commit it).

## Invariants
- Every component maps to one contract promise and one or more CNCF capability domains. When you add
  or change one, update the README matrix and `docs/frameworks/` and name the AKS-native alternative.
- The blog does not mention Cilium, Chainguard, or Cosign. Present them as this repo's extensions. Do not
  publish unverified performance claims. Do not claim "sockmap acceleration" (D-018); cite socket-LB and eBPF host routing.
- Contract v1 surface = `charts/golden-service` 1.x + XRD v1 + `reusable-build-sign.yaml@v1` + Kyverno
  policy set v1. A breaking change needs a major bump, an ADR, and a migration guide.
- Placement (D-023): every cluster, including in-cluster, is a declarative Argo CD cluster Secret with independent
  capability labels `platform.example.org/hosts-control-plane` and `platform.example.org/hosts-workloads`.
  Each ApplicationSet selects on one capability label, never on a cluster name; team apps also select the env's
  `platform.example.org/workload-group` from the team file, and their Application names carry the cluster (D-079). kind sets both labels.
- Tenant authorization is enforced at the backend, never by UI filtering (D-025). A backend is exposed to
  developers only after its cross-tenant deny test passes.
- App identity (ADR-0008): one UAMI per app per environment, federated to the app's ServiceAccount, created by a
  platform composition. App teams never write role assignments.
- `cilium_mode = managed|byo`: everything app-facing (HTTPRoute, CiliumNetworkPolicy, chart values)
  must work in both modes. Mode-specific config lives in `values-<mode>.yaml`.
- Crossplane v2: namespaced XRs in control-cluster `tenant-<team>-<env>` namespaces, no claims, function
  pipelines only, namespaced managed resources only (no `LegacyCluster`, D-024). Every XRD needs both an `azure` and a `local` composition. Connection secrets flow
  composed Secret → ESO PushSecret → Key Vault → ExternalSecret.
- Images: Chainguard bases only, as `:latest@sha256:<digest>` (the free tier is latest-only). Renovate
  owns the digest bumps. Never use unpinned tags.
- Tagging taxonomy (ADR-0007) is required on every Azure resource and app K8s object, and Kyverno
  enforces it. Tag values are derived from `platform/tenancy/teams/<team>.yaml`. Never add tag or
  cost-center fields to XRD schemas or Backstage template inputs (D-017).
- Network contract v1 = Gateway API v1.6.1 feature set in ADR-0003 (D-027). L7/FQDN policy is an optional
  add-on profile (ACNS on managed), never baseline (D-021).
- Image admission binds signer + caller repo/ref (via provenance) + verified base digest, with `failurePolicy: Fail` (D-026).
- Kyverno: every policy needs pass and fail `kyverno test` cases under `platform/policies/tests/`.
  Every message must give what failed, why, the fix, and a docs link.
- No developer path (doc, script, Backstage action) may require `cluster-admin`. Fixes go through Git PRs.
- Every journey in `docs/journeys/` must have a matching e2e test in `tests/e2e/`.
- Change the repo coordinates (`<org>/golden-path-k8s`) only via `scripts/render-repo-coords.sh`. They
  feed cosign identities, Argo CD repoURLs, and Backstage template targets.

## Working in parallel (D-089)
- The primary checkout (the clone's main working tree) stays on `main`. Start every task in its own worktree:
  `git worktree add ../golden-path-k8s-<task> -b <branch> origin/main`. Never `git checkout`/`git switch` a branch in
  the primary checkout; other agents share it. `make hooks` enables the hooks that enforce this.
- Shared local resources (the kind cluster `golden-path`, its Gitea) belong to one session at a time; coordinate before
  `make kind-down`/`kind-up`.

## Commands
<!-- Planned targets; none exist yet. Replace with verified commands as each phase lands. -->
- `make doctor [PROFILE=local|docs|github|cloud|all]`: prerequisite checks (D-056); setup guide in `docs/getting-started.md`
- `make tools`: pinned, checksum-verified CLIs into `./.bin` (D-048; upgrade path in `docs/toolchain.md`)
- `make kind-up` / `make kind-down` (Docker required; use WSL2 or Git Bash on Windows); `make kind-sync` pushes the working
  tree to the in-cluster Gitea (D-043). kind targets use `.kube/golden-path.yaml`, never the global current context
- `make validate`: all static checks (kubeconform, helm lint, `crossplane resource validate`, `crossplane composition render`
  golden files, terraform fmt/validate) (D-040)
- `make test-policies`. Single policy: `kyverno test platform/policies/tests/<policy-dir>`
- `make e2e JOURNEY=<dir>` (Chainsaw on kind)
- AKS (D-083, D-084): `make aks-preflight` (read-only), `make aks-plan`, `GP_CONFIRM_SUBSCRIPTION=<id> make aks-up`,
  `make aks-bootstrap`, `make aks-down` (runs `make aks-verify-teardown`). Never apply without the owner's confirmation
  of subscription, region, permissions, quota, budget, timeout and teardown owner
- `terraform -chdir=infra/envs/<env> init|plan` (Terraform, D-088); `terraform fmt -recursive -check infra && tflint --recursive`
- Backstage (`backstage/app`): `yarn install`, `yarn start`, `yarn tsc`, `yarn test`

## Docs
- ADRs: `docs/adr/` (template in `docs/adr/template.md`). Index and decision history: `docs/adr/README.md`.
- Build order is kind-first (D-016). Each phase is approved separately. Phase scope and exit criteria are in
  `docs/adr/README.md` ("Phases and exit criteria"). A phase is done only when every exit criterion passes.
