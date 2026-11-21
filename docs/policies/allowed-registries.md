# allowed-registries

**What it checks.** Every container image in a team namespace starts with `ghcr.io/joezuchora/golden-path-k8s/`, the
registry the platform pipeline pushes to (D-031). It applies to Pods and to the pod templates of Deployments, StatefulSets,
DaemonSets, Jobs and CronJobs.

**Why.** Only pipeline-built images carry the signature and attestations that `image-admission` verifies. An image from any
other registry would skip that check entirely, because an image policy matches only its own registry prefix. Chainguard
images aren't deployed directly either. The Chainguard base is checked *inside* your image, through its base-image
attestation (D-058).

**Fix.** Build the image with `reusable-build-sign.yaml@v1` and set `image:` in your golden-service values to the
`ghcr.io/joezuchora/golden-path-k8s/<name>@sha256:<digest>` it prints. Third-party software you need runs as a platform
component, not in a team namespace; ask the platform team.

**Tests.** `platform/policies/tests/allowed-registries/` covers a pipeline image (pass), a Docker Hub image (fail) and a
directly deployed Chainguard image (fail).
