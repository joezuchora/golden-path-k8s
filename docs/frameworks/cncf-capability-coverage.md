# CNCF capability coverage

Measured against the 13 capability domains in the **CNCF Platforms White Paper**, using the names from its "Capabilities of
platforms" table (F18). Each component is listed under its primary domain and its one contract promise, exactly as in the
[README matrix](../../README.md#developer-contract-matrix).

**Status vocabulary:**
- *Designed*: specified in an ADR; not yet proven.
- *Proven*: its fitness check passes (none yet, since Phase 3 is the first build phase).
- *Partial*: designed, with a stated gap.
- *Deferred*: out of v1, with a reason (D-033).

## Domains

| # | Domain | Components | Promise | v1 status | Gap or reason |
|---|---|---|---|---|---|
| 1 | Web portals for provisioning and observing capabilities | Backstage (Kubernetes plugin, `aks` auth on AKS) | P3 | Designed | On kind, Backstage is a demo with a shared read-only service account, not tenant isolation (D-025) |
| 2 | APIs for automatically provisioning capabilities | Crossplane v2 (namespaced XRDs + function pipelines, `provider-upjet-azure`) | P1 | Partial: proven on kind (`local` composition, J4); `azure` validated and render-tested, live in Phase 4 | — |
| 3 | Golden path templates and docs | `golden-service` Helm chart 1.x; Backstage software templates (Go, Python, .NET); [Developer Contract](../developer-contract.md) | P4 | Partial: `golden-service` 1.0.0 proven on kind (J1–J4, network contract); Backstage templates in Phase 5 | Templates arrive in Phase 5 |
| 4 | Automation for building and testing products | `reusable-build-sign.yaml` (GitHub Actions); Renovate | P4 | Partial: `reusable-build-sign` proven in CI (build-hello signs, attests and passes its own admission check); Renovate in Phase 6 | — |
| 5 | Automation for delivering and verifying services | Argo CD (GitOps sync, per-team AppProjects, UI and notifications); Argo CD placement (cluster Secrets + capability labels) [P1]; Gitea (kind e2e Git host only); Chainsaw e2e + `kyverno test` fitness checks | P4 | Partial: Argo CD, placement, Gitea and Chainsaw proven on kind (all suites); no automated progressive delivery (D-032) | No automated progressive delivery (D-032); the blog marks this row Not built in on AKS too (F16) |
| 6 | Development environments | — | — | **Deferred** | kind is the platform's own test bed, not an app dev environment; no v1 journey needs one (D-033) |
| 7 | Application observability | Prometheus; Grafana (one org per team) + prom-label-proxy; Hubble (`byo`/kind; platform-only UI); OpenCost; `scripts/idp-diagnose.sh`; Tagging and ownership taxonomy (Kyverno mutate, Crossplane tags, Azure Policy) | P3 | Partial: `idp-diagnose.sh` (J3) and the label taxonomy (J1, J4) proven on kind; metrics, Grafana and OpenCost in Phase 6; no aggregated logs or tracing (D-033) | Metrics, flows and cost are designed. Aggregated logs and distributed tracing are not in v1 (D-033). The blog's BYO column lists the OpenTelemetry Collector (F16) |
| 8 | Infrastructure services | AKS Standard control + workload clusters; kind (local profile); Tenancy render (`platform/tenancy/teams/<team>.yaml`); Cilium CNI (`managed`: Azure CNI Powered by Cilium; `byo`/kind: OSS Cilium); OpenTofu (`infra/`) [P1]; Gateway API v1.6.1: Envoy Gateway (`managed`), Cilium Gateway (`byo`, kind); ExternalDNS [P2] | P1, P2 | Partial: kind, tenancy, Cilium and the Gateway proven on kind (placement, O1, network contract); AKS and OpenTofu in Phase 4 | — |
| 9 | Data services | PostgreSQL compositions (`azure`: Flexible Server; `local`: CloudNativePG) | P1 | Partial (PostgreSQL only): proven on kind with CloudNativePG (J4); Azure Flexible Server in Phase 4 | Redis is a catalog-expansion example, not a v1 promise |
| 10 | Messaging and event services | — | — | **Deferred** | No v1 journey needs it; each addition is another component to run (D-033, F21) |
| 11 | Identity and secret services | Entra Workload ID with one UAMI per app per env (`AppIdentity` XR); External Secrets Operator + Key Vault (`PushSecret` → `ExternalSecret`); Reloader; cert-manager | P2 | Partial: ESO, Reloader and cert-manager proven on kind (J1, J4); Workload ID and Key Vault in Phase 4 | kind uses a brokered password instead of federation (ADR-0008) |
| 12 | Security services | `CiliumNetworkPolicy` default-deny baseline (L3/L4) [P1]; Azure Front Door Premium + WAF (opt-in, `enable_edge_waf`); ACNS L7/FQDN policy profile (optional; `managed` only) [P2]; Chainguard base images (`:latest@sha256:`); Cosign keyless + SLSA provenance + SPDX SBOM; Trivy (CI gate) + Trivy Operator; Kyverno policy set v1 (admission, mutation, `PolicyReport`s) [P4] | P1, P2, P4 | Partial: the Kyverno policy set, Cosign keyless, Chainguard bases and the network baseline proven (`make test-policies`, J1, J2, network contract); WAF and ACNS in Phase 4, Trivy Operator in Phase 6 | — |
| 13 | Artifact storage | GitHub Container Registry (GHCR) | P4 | Proven: GHCR (build-hello publishes; kind pulls the signed digest anonymously, F48) | ACR + Defender is the AKS-native alternative (D-031) |

Where a domain spans promises, each component's promise is shown in brackets. Every component still has exactly one promise.

## The 7 platform attributes (F18)

| Attribute | Where this repo addresses it |
|---|---|
| Platform as a product | The versioned [Developer Contract](../developer-contract.md), with metrics and RACI (D-036–D-038) |
| User experience | Two inputs (`app`, `env`); every denial gives what, why, the fix and a docs link (ADR-0005, ADR-0006) |
| Documentation and onboarding | This repo's docs; journeys arrive in Phase 3, each with a matching e2e test |
| Self-service | XRs, Backstage templates, `idp-diagnose.sh`; no developer path needs `cluster-admin` (ADR-0006) |
| Reduced cognitive load for users | Tags, identities and policies are derived, not entered (D-017, D-022) |
| Optional and composable | Opt-in WAF (D-007), optional L7/FQDN profile (D-021), `cilium_mode` (D-005), escape hatches |
| Secure by default | Default-deny network policy, fail-closed admission (D-026), per-app identity (D-022) |

## Keeping this current

When a component is added or changed, update the README matrix, this file and the Decision Log in the same change
(CLAUDE.md invariant). `scripts/verify-docs.sh` fails when a matrix component is missing here or a domain name isn't canonical.
