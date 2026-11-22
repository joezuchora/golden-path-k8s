# ADR-0003: Cilium eBPF + Gateway API over Ingress-NGINX and sidecar meshes

- **Status:** Proposed
- **Date:** 2026-11-20
- **Contract promise:** P1 A place to run (default-deny network-policy boundary) · P2 An identity (HTTPS URL via Gateway API)
- **CNCF capability domain(s):** Security services; Application observability; Infrastructure services
- **Related decisions:** D-004 (Revisited), D-005, D-006, D-018, D-021, D-027 (Revisited), D-029, D-039, D-041, D-057

## Context
The original requirement was Azure CNI Powered by Cilium with Cilium's built-in Gateway API (D-004).
Verification (F3) showed that only label exclusion can be changed in the AKS-managed Cilium ConfigMap, so
Cilium's Gateway API can't be enabled there. L7 and FQDN policy require Advanced Container Networking Services
(ACNS); kube-proxy is not used. The AKS blog does not mention Cilium (F1). It places "Your app gets an HTTPS URL"
(application routing with the Gateway API, or your own Gateway controller with cert-manager) under "An identity", and
network policy under "A place to run" ("Your app gets its own boundary") (F16). This ADR follows that split (D-029):
the gateway serves P2, and the CNI and `CiliumNetworkPolicy` serve P1. Cilium as the dataplane and the L7/FQDN profile
are this repo's extensions. Sidecar meshes add CPU, memory and
upgrade coupling to every pod. Ingress-NGINX is retired (F10): the repo "was archived by the owner on Mar 24, 2026",
gets no security fixes, and its README tells new users to "identify a Gateway API implementation and use it". The
Kubernetes blog ("Ingress NGINX Retirement: What You Need to Know", 2025-11-11) recommends that "all Ingress NGINX users
begin migration to Gateway API" (attribution corrected in D-041).

## Decision drivers
- Apps get a stable network contract: `HTTPRoute` + `CiliumNetworkPolicy` (L3/L4 baseline, L7/FQDN optional), default deny.
- Microsoft support for the CNI by default.
- The same behavior locally and on AKS.
- No per-pod sidecars.

## Options considered
| Option | Pros | Cons |
|---|---|---|
| kube-proxy + Ingress-NGINX | Familiar | Retired and archived 2026-03-24, no security fixes (F10); iptables scale limits; Ingress API is legacy. Ruled out |
| Istio sidecar / ambient (AKS add-on) | mTLS, rich L7 | Sidecar overhead (sidecar mode); a second control plane |
| **AKS-native:** managed Cilium + ACNS + Envoy Gateway | Microsoft-supported CNI; OSS gateway | ACNS is a paid add-on; two components |
| **AKS-native:** managed Cilium + application routing with Gateway API | Fully managed; the AKS blog's recommended default ingress path (F59) | Less portable: Istio-based (`approuting-istio`), AKS-managed Gateway API CRDs only, so the CRD source differs from kind and byo (F59, D-096) |
| BYO OSS Cilium (`network_plugin=none`) | Full Cilium: Gateway API, Hubble, L7; same as kind | Microsoft doesn't support the CNI; the team owns Cilium upgrades (the "plumbing" the blog warns about) |

## Decision
Dual mode via `cilium_mode` (D-005):
- `managed` (default): Azure CNI Powered by Cilium (overlay) plus a separate Gateway API controller:
  **Envoy Gateway** (D-006, reaffirmed in D-096 as a stated deviation from the blog's default; target version v1.10.0,
  D-097). ACNS is **not** required for the baseline; it is the prerequisite for the optional L7/FQDN add-on profile
  (D-021).
- `byo`: `network_plugin=none` with OSS Cilium installed by Helm (`kubeProxyReplacement=true`, Gateway API, Hubble).
- `kind`: OSS Cilium using the same values as `byo`.

Apps depend only on `HTTPRoute` and `CiliumNetworkPolicy`; the mode changes only the `GatewayClass`.

**v1 network feature set (D-027).** Portability is a tested promise, not an inference from both controllers using Envoy.
- **Pinned versions:** Gateway API v1.6.1. Both controllers pass its conformance at the versions pinned here:
  Envoy Gateway v1.9.0 and Cilium v1.20.0, GATEWAY-HTTP/GRPC/TLS profiles, zero failures (F14). That is the
  **conformance basis**. The installed patches follow D-039 (Gateway API CRDs v1.6.3, which Cilium 1.20 requires (F30);
  Envoy Gateway v1.9.3; Cilium 1.20.4), and the network-contract suite re-proves every promised feature on them.
- **Promised route features (v1):** HTTPS listener with a cert-manager certificate, host and path-prefix matching,
  header matching, weighted backends (for canaries), request and response header modifiers, and HTTP→HTTPS redirect.
  Each feature must be in the conformance set that both controllers pass; anything else is out of v1.
- **Promised policy semantics (v1):** default-deny ingress and egress per namespace; L3/L4 allows by label and port;
  DNS egress to kube-dns; ingress only from the gateway. L7 HTTP rules and FQDN egress make up the **optional
  add-on profile**: free on byo and kind, and requiring ACNS on managed (a stated cost of that profile).
Performance claims cite only documented features: socket-LB ("Cilium's kube-proxy replacement depends on the
socket-LB feature") and eBPF host routing. The original "sockmap acceleration" claim is dropped because current
Cilium docs don't support it (F7, D-018). Any benchmark numbers must come from this repo's own measurements.
On kind, Cilium runs with iptables masquerading, because eBPF masquerading breaks pod DNS on Docker Desktop (F40, D-057),
so eBPF host routing is a `byo` property, not a kind one; kube-proxy replacement and socket-LB run on kind.

## Consequences
- Positive: Microsoft supports the CNI by default; full Cilium is available as an opt-in; a portable app contract.
- Negative: three test profiles (kind, managed AKS, byo AKS); ACNS cost if a managed cluster adopts the L7/FQDN
  add-on; Hubble UI only in byo and kind.
- Escape hatch: teams that need mesh features (mTLS identity between services) open an ADR; it isn't in v1.

## Fitness check
One Chainsaw suite (`tests/e2e/network-contract/`) asserts every v1 route feature and every baseline policy
semantic, and runs unchanged against **three separate profiles**:

| Profile | When it runs | Extra assertions |
|---|---|---|
| kind | Every PR | L7/FQDN add-on (free here) |
| managed AKS | On demand before declaring AKS support; then on a cadence set from measured cost and runtime | L7/FQDN only if the ACNS add-on is enabled |
| byo AKS | Same as managed | L7/FQDN |

Each AKS job has a timeout, an owner, and a teardown check, so an interrupted run shows up as a visible failure
and doesn't silently leak resources. The suite also asserts that the controller versions match the pinned ones.
