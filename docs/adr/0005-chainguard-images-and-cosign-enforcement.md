# ADR-0005: Chainguard images with Kyverno Cosign enforcement

- **Status:** Proposed
- **Date:** 2026-11-20
- **Contract promise:** P4 A safe way to ship
- **CNCF capability domain(s):** Security services; Artifact storage; Automation for building and testing products
- **Related decisions:** D-008 (Revisited), D-026, D-014, D-019, D-031

## Context
Vulnerability scanning finds known CVEs but proves nothing about where an image came from or what it was
built from. The AKS blog notes that ACR and Defender "don't sign application images for you" and names
Ratify/Notation (F17); it does not mention Chainguard or Cosign (F1). The Chainguard free tier offers `:latest` tags
only, and public images are signed keyless by Chainguard's GitHub release workflow (F5). Every base this repo needs
(`go`, `static`, `python`, `dotnet-sdk`, `aspnet-runtime`, `node`, and others) can be pulled anonymously at `:latest` and
`:latest-dev`; versioned tags cannot (F6, verified 2026-11-20).

## Decision drivers
- Cryptographic proof that an image was built by the platform's approved pipeline from an approved base.
- Minimal base images with few CVEs.
- Admission-time enforcement with clear, fixable error messages.

## Options considered
| Option | Pros | Cons |
|---|---|---|
| Trivy scanning only | Simple | No provenance; a scan can't stop an image built outside the pipeline |
| **AKS-native:** Defender for Containers | Managed scanning and posture | No signature enforcement on its own |
| **AKS-native:** Ratify + Notation + Deployment Safeguards | The blog's path; Azure-integrated | Notation ecosystem is narrower than Sigstore's; Gatekeeper-based |
| **Kyverno `verifyImages` + Cosign keyless** | Sigstore ecosystem; checks both signatures and attestations; same engine as the other policies | Fulcio and Rekor become dependencies |
| sigstore policy-controller | Purpose-built | A second admission engine |
| Registry: **GitHub Container Registry (GHCR)** | Free for a public repo; the same registry serves kind, CI and the real-registry admission tests; native GitHub Actions auth | Not Azure-integrated; no Defender scanning in the registry |
| Registry, **AKS-native:** ACR + Defender for Containers | The blog's "On AKS" path (F16); managed scanning; private networking | Cost per registry; kind and CI need Azure credentials to push or pull, which works against kind-first (D-016) |

## Decision
- One reusable workflow (`reusable-build-sign.yaml`) builds every app image:
  1. `cosign verify` the Chainguard base against the F5 identity.
  2. Build the image.
  3. Gate on Trivy (fixable High/Critical findings).
  4. Sign with Cosign keyless. The certificate SAN, Fulcio's Build Signer URI (OID 1.3.6.1.4.1.57264.1.9), is the
     reusable workflow's `job_workflow_ref`.
  5. Attest an SPDX SBOM, plus a `base-image` predicate whose `digest` is **the exact base digest verified in step 1
     and used by the build**, taken from the build's own resolved-base metadata and never re-resolved from the tag.
- **Admission binds three things (D-026).** The signer identity alone proves *how* an image was built, not *for whom*,
  because any repository can call a public reusable workflow. So Kyverno `verifyImages` requires all of these:
  1. **Signer**: subject = the pinned reusable workflow ref; issuer = GitHub Actions.
  2. **Caller**: the source repository and ref must be on the allowlist for the target namespace's team (derived
     from the team definition, ADR-0007). Fulcio carries these as Source Repository URI and Ref (OIDs 1.12 and 1.14), but
     Kyverno documents only the GitHub-specific `additionalExtensions` (`githubWorkflowRepository`, …), whose OIDs
     Fulcio marks as **deprecated** (F15). So the caller is checked from a **signed SLSA provenance attestation**,
     using `attestations` conditions on its repository and ref fields. The deprecated extensions are not relied on.
  3. **Base**: the `base-image` attestation's digest must be in the set of Chainguard digests the platform has
     verified (maintained by Renovate). A `cgr.dev/` prefix alone isn't enough.
  - `mutateDigest` pins references to digests. Any `cgr.dev` image deployed directly is verified against the
    Chainguard identity.
- **Failure mode: fail closed.** Kyverno's docs don't state a default for an unreachable registry or Rekor (F15), so the
  policy sets `failurePolicy: Fail` explicitly. New or changed pods are rejected while verification is unavailable;
  running pods are unaffected. Kyverno caches only *successful* verifications (default TTL 60m, max 1000 entries), so
  recently verified digests keep deploying through short outages. The outage runbook documents a time-boxed,
  audited `PolicyException` as break-glass.
- **Registry (D-031):** the reusable workflow pushes app images, signatures and attestations to GHCR. ACR with Defender
  is the documented AKS-native alternative. Switching is a change to the workflow's registry input, plus the admission
  policy's image pattern, and needs no app change.
- Trivy Operator rescans running images continuously. Renovate bumps base-image digests.
- Bases are referenced as `:latest@sha256:<digest>`. Builds use `-dev` variants and runtimes use the minimal variants.
  Because `:latest` moves across language major versions (for example Python 3.x → 3.y), each Renovate digest PR must
  pass the app's tests before merge. Paid versioned tags are the documented upgrade path (D-019).

## Consequences
- Positive: only images built by the approved pipeline from an approved base reach the cluster.
- Negative: availability of Fulcio and Rekor matters (document the cache and outage plan); admission adds latency;
  the free tier can't pin a language version, so a major-version jump arrives as a digest PR (D-019).
- Escape hatch: a time-boxed `PolicyException` with an owner, a reason and an expiry date, reviewed by the platform team.

## Fitness check
- **`kyverno test` (every PR):**

  | Case | Expected |
  |---|---|
  | Unsigned | deny |
  | Wrong signer | deny |
  | Missing attestation | deny |
  | Non-`cgr.dev` base | deny |
  | Tag-only reference | mutated to a digest |
  | Valid | allow |

- **Real-registry e2e (kind, every PR), with images actually built and signed by CI:**

  | Case | Expected |
  |---|---|
  | Valid image from an allowlisted repo | admitted |
  | **Disallowed caller repo using the same reusable workflow** | denied |
  | **Base digest mismatch** (attestation digest not in the verified set) | denied |
  | Registry made unreachable | new pod denied, running pod untouched |

- **Latency:** measure admission latency cold (cache empty) and warm (cache hit) and publish both numbers. Don't
  estimate them.
- Every deny message gives what failed, why, the fix, and a docs link.
