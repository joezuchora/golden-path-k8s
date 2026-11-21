# ADR-0004: Edge security and WAF

- **Status:** Proposed
- **Date:** 2026-11-20
- **Contract promise:** P2 An identity (the edge of the HTTPS URL; the WAF is this repo's extension)
- **CNCF capability domain(s):** Security services
- **Related decisions:** D-007, D-029

## Context
Public HTTPRoutes need TLS (cert-manager with Let's Encrypt) and DNS (ExternalDNS). Production services usually
also need protection from the OWASP Top 10 and from bots and DDoS at the edge. A WAF has a fixed monthly cost
that would dominate a demo deployment.

## Decision drivers
- Secure by default without forcing a fixed cost on every user of the repo.
- Origin lock: the cluster gateway can't be reached directly once the edge exists.
- Managed rule sets over hand-tuned rules.

## Options considered
| Option | Pros | Cons |
|---|---|---|
| No WAF (Gateway + cert-manager only) | Free, simple | No L7 edge protection |
| **AKS-native:** Azure Front Door Premium + WAF | Managed rules, bot protection, global edge, Private Link origin | Premium base fee plus per-request charges |
| **AKS-native:** Application Gateway for Containers + WAF | Regional, Gateway API integration | Regional only; another controller |
| OSS Coraza in the gateway | No added cloud cost | Rule tuning and operations fall on the platform team |

## Decision
`enable_edge_waf = false` by default. An opt-in Terraform module (D-088) deploys Azure Front Door Premium with a WAF
policy (managed rule set plus bot manager) and a Private Link origin to the gateway's internal load balancer.
TLS is split: an AFD-managed certificate at the edge and cert-manager at the origin. Costs will be computed
from the Azure pricing page in Phase 3, not estimated.

## Consequences
- Positive: no default cost; a production-grade edge available behind one flag.
- Negative: two TLS configurations to operate; the AFD path differs from kind.
- Escape hatch: per-route WAF exclusions are requested through a PR to the WAF policy, with an owner and expiry date.

## Fitness check
With the module enabled: a request straight to the origin is refused, a request through AFD succeeds, and
a known-bad payload (an OWASP test string) is blocked. Checked in the AKS nightly.
