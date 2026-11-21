# ADR-0009: Terraform for AKS foundations

- **Status:** Proposed
- **Date:** 2026-11-21
- **Contract promise:** P1 A place to run
- **CNCF capability domain(s):** Infrastructure services
- **Related decisions:** D-088 (revisits D-013), D-083, D-084, D-024

## Context
Phase 4 provisions the platform-owned Azure foundations: the network, the AKS control and workload clusters, the platform
identities and a tenant (resource group, Key Vault, ESO identities) per team and env (D-083). Developer-requested
dependencies stay on Crossplane, which reconciles them continuously through the Kubernetes API (ADR-0002); this ADR
covers only what the platform team provisions. The original plan (D-013) favored OpenTofu for its open-source license and
kept the HCL Terraform-compatible. The project owner selected HashiCorp Terraform for the reference implementation.

## Decision drivers
- One documented, tested CLI path for the platform team and for readers who run Terraform.
- Reproducible versions: the engine and providers are pinned and checksum-locked like every other tool (D-048).
- Keep the boundary clear: platform foundations in Terraform state, app dependencies in Crossplane.

## Options considered
| Option | Pros | Cons |
|---|---|---|
| **Terraform** | The CLI the owner selected; the most widely used HCL engine | Releases from 1.6.0 on use the Business Source License, with an additional use grant that excludes offering it as a competing hosted product (F58) |
| OpenTofu, HCL kept Terraform-compatible (D-013) | MPL 2.0; the same HCL | A second engine to keep compatible if Terraform users are also supported |
| **AKS-native:** Bicep / Azure Verified Modules | Azure's own deployment tooling | Different modules and operations; no reuse with other clouds |

## Decision
HashiCorp Terraform, pinned to v1.17.1 in `tools/versions.env` and installed by `make tools` from HashiCorp's release
checksums, with tflint for static analysis. Providers are locked for every supported platform from
`registry.terraform.io`. The HCL uses no engine-specific features, so a fork can still run it with OpenTofu, but only
Terraform is tested.

## Consequences
- Positive: one CLI in the installer, the docs, `make validate`, the cloud preflight and `infra/aks/aks.sh`.
- Negative: the engine isn't open source in the OSI sense; the license terms are stated rather than assumed (F58).
- Escape hatch: OpenTofu can run the same HCL; supporting it again would mean a second CI path and lock file.

## Fitness check
`make validate` runs `terraform fmt -check`, `init` (no backend, read-only lock) and `validate` for each root, the lock's
platform coverage, the tag lint and tflint on every PR. The ADR stays Proposed until a disposable AKS environment has been
planned, applied and torn down with the pinned CLI, and `infra/aks/aks.sh verify-teardown` reports nothing left.
