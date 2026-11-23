# Toolchain and upgrade path

Every CLI and every platform component is pinned in [`tools/versions.env`](../tools/versions.env), the machine-readable copy of
the [Version pins](adr/README.md#version-pins) table (D-039). `make tools` installs the CLIs into `./.bin`. Nothing is
installed globally, and the Makefile puts `./.bin` first on `PATH` (D-048).

## How a download is trusted

Each CLI download passes two checks in [`tools/install.sh`](../tools/install.sh):

1. **Upstream:** its SHA-256 matches the checksum the project publishes for that exact release.
2. **Lock:** its SHA-256 matches [`tools/checksums.lock`](../tools/checksums.lock), keyed by tool, version, OS and asset. The
   lock is committed, so a re-published asset can't change silently.

A version with no lock entry is refused. Recording one is a deliberate step (`--lock`) whose diff is reviewed in the PR.

The Crossplane CLI is the one exception to "download the binary". Its bare Linux and Windows binaries don't match their own
published checksums (F34), so it is installed from the bundle tarball, whose checksum does match (D-054).

## Upgrading a pin

1. **Check eligibility.** The release must be stable and at least 14 days old (D-039). For network components, the new
   version must stay within a minor that has conformance evidence, or it needs a new F-entry with that evidence.
2. **Trial without editing anything:** any pin can be overridden from the environment. Export it, so that every later
   command, including the `tools` step that `make validate` and `make test-policies` run first, uses the trial version:
   ```bash
   export CROSSPLANE_CLI_VERSION=v2.4.1
   bash tools/install.sh --lock crossplane            # this platform: verify against upstream, record the lock entry
   for p in linux-amd64 linux-arm64 darwin-amd64 darwin-arm64 windows-amd64; do
     bash tools/install.sh --lock-platform "$p" crossplane   # the other platforms, from the published checksums
   done
   make validate test-policies
   unset CROSSPLANE_CLI_VERSION
   KYVERNO_CHART_VERSION=3.10.0 make kind-down kind-up && make e2e-all   # platform components work the same way
   ```
3. **Make it permanent:** update `tools/versions.env` and the Version pins row (source + date) in the same PR, and keep the new
   lock lines for all five platforms. Only then remove the lock lines for versions no longer referenced. A cached binary is
   reused only while its lock entry and its own digest are unchanged, so editing the lock forces a fresh verified download.
   A Crossplane function bump also sets `<pkg>:<version>@sha256:<index digest>` in `crossplane-config/values.yaml` and
   `render-tests/functions.yaml` (`docker buildx imagetools inspect <pkg>:<version>` prints the digest); `make validate`
   fails until all three agree (D-093).
4. **Prove it:** the PR's `validate`, `test-policies` and kind e2e jobs must pass. A minor or major bump of a contract-surface
   component (Kyverno policy APIs, Gateway API, XRD API versions) also follows ADR-0010.

## Renovate

On 2026-11-23, the Mend Developer Portal showed Renovate enabled for `joezuchora/golden-path-k8s` on the
Community (Free) plan in Interactive mode. The portal showed no completed job at setup, so the first run
is pending verification. Check the portal's **Last Job Run** or look for the **Dependency Dashboard** issue in GitHub.

The [repository configuration](../renovate.json) covers Chainguard image digests outside admission and GitHub Actions
pins (D-091). Review and merge Renovate PRs manually after `static` and `kind-e2e` pass (D-092). Pins in
`tools/versions.env` and the admission-bound runtime base (`cgr.dev/chainguard/static`) follow the manual process above.

## Version skew that is allowed

| Pair | Rule |
|---|---|
| Crossplane CLI vs. core | Same minor; the CLI may lag (CLI builds aren't published for every core patch, F34) |
| kubectl vs. kind node | Same minor |
| Kyverno CLI vs. Kyverno in the cluster | Same version (policy tests must match admission) |
| argocd CLI vs. Argo CD | Same version |
