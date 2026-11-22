# image-admission

**What it checks.** Every container image under `ghcr.io/joezuchora/golden-path-k8s/` in your namespace must:

1. be **signed** keyless by the platform pipeline `reusable-build-sign.yaml` at `refs/heads/main` or a `v1` tag (on kind,
   also this repo's branches, so a platform PR can prove itself before merge, D-055);
2. carry a signed **SLSA v1 provenance** attestation whose caller repository and ref are on your team's allowlist
   (`callers:` in `platform/tenancy/teams/<team>.yaml`);
3. carry a signed **base-image** attestation whose digest is listed in `platform/policies/verified-bases.yaml`.

Tags are rewritten to digests on admission (`mutateDigest`). If the registry or Rekor can't be reached, new or changed pods
are rejected and running pods are untouched (fail closed, ADR-0005). Successful verifications are cached (default 60
minutes, F25), so recently verified digests keep deploying through short outages.

**Why.** The signer proves *how* an image was built. The provenance proves *for whom*, because any repository can call a
public reusable workflow. The base digest proves *what it was built from*, which a `cgr.dev/` prefix alone doesn't (D-026).

**Fix, by message.**

| Message | Fix |
|---|---|
| "isn't signed by the platform pipeline" | Build through `reusable-build-sign.yaml@v1` (see `.github/workflows/build-hello.yaml`) and deploy the digest it prints. A laptop signature is rejected by design. |
| "wasn't built from a repo and ref that team … allows" | Build from `main` or a `v1` tag of an allowed repo, or add the caller to `callers:` in your team file by PR (the platform team reviews it). |
| "base isn't a Chainguard digest the platform has verified" | Rebase your Dockerfile's `BASE_IMAGE` onto a digest listed in `platform/policies/verified-bases.yaml` (Renovate opens these PRs) and rebuild. |
| Verification service unavailable (registry, Fulcio/Rekor) | Wait, or page the platform on-call. The runbook allows a time-boxed `PolicyException` as break-glass. |

**What the base attestation proves.** Before attesting, `reusable-build-sign` checks that the published image's layers
begin with the verified base's layers, so the attested digest is the base the image actually runs on (D-069). Builder
stages (for example `go:latest-dev`) aren't covered: they don't ship, and only the runtime base is bound.

**Stated limits (v1).** Images are published under the calling repo's GHCR namespace, while `allowed-registries` admits
only this repo's prefix, so a team building from its own repo needs its prefix added to the policy values. Who may change
the reusable workflow, its tags, the caller allowlists and branch protection is part of the GitHub organization baseline
(Phase 6), together with what happens when a repo is renamed or transferred.
In this repo, `main` itself is protected by a ruleset (PR only, required checks, no force-push; D-092).

**Tests.** Two suites run the same three fixtures from `tests/e2e/lib/images.env` against each rendering of the policy
(D-095). `platform/policies/tests/image-admission/` (kind): an image signed by CI from `main` (pass), the same app signed
by CI from a branch (pass, because kind accepts this repo's branch refs, D-055), and an unsigned image under the same
prefix (fail). `platform/policies/tests/image-admission-aks/` (AKS): `main` (pass), branch (fail: a disallowed signer
ref), unsigned (fail). `make test-policies` fails if the fixtures drift from `images.env`. The tests are online: they need
GHCR and Rekor (F35).
