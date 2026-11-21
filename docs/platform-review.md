# Platform review from four roles

Reviewed Phase 3 at `93da30a` against the [Developer Contract](developer-contract.md) and its
[open questions about platform fit](design-evolution.md#open-questions-about-platform-fit).
The dispositions below are recommendations for discussion. The review used source inspection
and selected local checks. Live admission, GitHub organization settings, and AKS behavior
still need evidence.

Start with the signed-image gate, the signing workflow's input and base checks, and hostname
ownership. These affect the evidence for safe delivery and tenant isolation today. Before
AKS adoption, prioritize one complete private dependency path and a recovery drill. Publish
the workload, fleet, and brownfield support boundaries alongside those gates.

## Application developer

### Give app teams useful feedback before merge

**Prove before onboarding a real team.** J2 deliberately merges a bad deploy PR and checks
the post-merge denial. The GitHub PR workflow runs in the platform repo. A team deploy repo
still needs a required check that renders its changed values and checks current policy.
J1 and O1 also use operator refresh and seeding helpers. Run one new team through repo
access, review, merge, reconcile, and first HTTPS response without those helper actions.
Publish a usable example of the cross-repo workflow reference alongside that proof.
[Platform PR workflow](../.github/workflows/pr-checks.yaml) ·
[J1 delivery helper](../tests/e2e/lib/app.sh) · [O1 onboarding](journeys/o1-onboard-team.md)

### Make failed and recovering rollouts diagnosable

**Fix before the Phase 3 diagnostics claim.** The diagnosis script can report healthy
while only old Deployment replicas are ready or the HTTPRoute has no observed status.
It also conflates a failed read with an absent resource. The Git status gives a command
using the Argo application name alone, while the CLI requires app, environment, and team.
Verify current rollout and route conditions, distinguish unknown from healthy, and have
J3 assert that the exact published command works with team credentials.
[Diagnosis CLI](../scripts/idp-diagnose.sh) ·
[Argo status template](../platform/bootstrap/argocd-values.yaml) ·
[J3 assertions](../tests/e2e/j3-unhealthy-rollout/unhealthy.sh)

### Match the dependency input to how apps consume it

**Fix before stabilizing the chart API.** The schema accepts multiple PostgreSQL dependency
names and the chart renders a secret binding for each. The container's database environment
variables use only the first. Either validate a single database or define named bindings,
then prove what happens when an app declares two. This avoids creating a database the
documented app interface cannot use.
[Values schema](../charts/golden-service/values.schema.json) ·
[Secret bindings](../charts/golden-service/templates/dependencies.yaml) ·
[Container environment](../charts/golden-service/templates/_helpers.tpl)

### Show how a team gets back to the last good release

**Prove before production promotion.** J3 verifies that the team receives a hint to revert.
Add a two-release journey that reverts through Git and proves the previous digest and HTTPS
response are back. Define the retention window for that digest, its attestations, and its
base allowlist entry. Describe how database changes can constrain an app rollback.
[Current J3 journey](journeys/j3-unhealthy-rollout.md) · [Delivery contract](developer-contract.md)

### Describe which workloads fit the current chart

**Document now.** The chart builds a Deployment and Service with an HTTP container,
read-only root, liveness and readiness probes, and a fixed resource model. A slow-starting
inference service, a queue-based training job, a stateful brownfield service, or a team asking
for serverless or microVM isolation needs an explicit decision about fit. Describe the
supported baseline and what separate profiles would have to prove, including lifecycle,
identity, diagnostics, and operator support.
[Chart workload template](../charts/golden-service/templates/workload.yaml) ·
[Container defaults](../charts/golden-service/templates/_helpers.tpl)

## Infrastructure engineer

### Recover a kind cluster when its local kubeconfig is gone

**Fix before calling bootstrap repeatable.** The Makefile uses a dedicated kubeconfig.
If that file is lost and the Docker nodes still exist, `kind-up` takes the existing-cluster
branch without recreating the config, then fails at its first Kubernetes call. Export
the existing cluster's config before applying anything and exercise that rerun case.
[Makefile kubeconfig](../Makefile) · [Cluster reuse path](../infra/kind/bootstrap.sh)

### Prove placement with two workload clusters

**Guard Phase 4 or prove multi-cluster placement.** The app ApplicationSet pairs every app
and environment with every selected workload cluster, but the generated Application name
has no cluster component. A second spoke introduces name collisions and no authoritative
team or environment assignment. Declare the single-workload-cluster limit for a first
release, or prove explicit placement and unique Application names against two spokes.
[Tenant ApplicationSet](../platform/tenancy/chart/templates/control-plane.yaml) ·
[Cluster topology ADR](adr/0001-control-and-workload-cluster-split.md)

### Prove private connectivity from the app to its dependency

**Prove on AKS.** The Azure PostgreSQL composition disables public access, while the
service chart only renders its database egress rule for the in-cluster backend. The Azure
secret payload and the workload consumer also need a shared key and field contract.
Prove one request from the workload namespace through private DNS and controlled egress
to an Entra-authenticated query. For hybrid networks, document who owns subnets, routes,
firewalls, DNS forwarding, and IP overlap checks. Prove an approved and a denied private
path before advertising hybrid support.
[Azure composition](../platform/components/crossplane-config/compositions/azure/postgresqlinstance.yaml) ·
[Egress template](../charts/golden-service/templates/network.yaml) ·
[Secret binding](../charts/golden-service/templates/dependencies.yaml)

### Recover the management plane from a clean start

**Prove before calling the AKS topology operational.** Git is the delivery source, but a
Git revert cannot repair an unavailable Argo CD hub or a spoke that the hub cannot reach.
The kind bootstrap applies its root app and cluster registration outside Git reconciliation.
Define who rebuilds the hub, restores credentials and registration, and resumes reconciliation.
Exercise a hub rebuild or disconnect and reconnect while spoke traffic remains healthy and
existing cloud resources retain their ownership.
[Kind bootstrap](../infra/kind/bootstrap.sh) · [Cluster topology ADR](adr/0001-control-and-workload-cluster-split.md)

### Make fail-closed admission survive routine maintenance

**Prove before production AKS.** Shared Kyverno values specify one admission replica and
the tenant policy fails closed. Losing that replica can block new deployments and
replacement Pods. Define a production availability profile and expected behavior when
the registry, signature verification, or one webhook replica is unavailable. Exercise a
node drain and verify that replacement capacity remains within quota.
[Kyverno values](../platform/components/kyverno/values.yaml) ·
[Tenant admission policy](../platform/tenancy/chart/templates/policies.yaml) ·
[Kyverno high availability guidance](https://kyverno.io/docs/guides/high-availability/)

### Make brownfield adoption and data retirement explicit

**Document now and prove before adopting existing workloads.** Applying the greenfield
tenancy defaults to a preexisting namespace can change its network or Pod Security
behavior. Deleting an XR from the deploy repo can also prune it, and J4 deliberately
asserts deletion of the disposable database. Define inventory, ownership handoffs, policy
assessment before enforcement, and rollback of the original delivery path. Prove an
observe-only adoption of existing infrastructure and a restore before applying the
development deletion model to durable data.
[Tenancy defaults](../platform/tenancy/chart/templates/workloads.yaml) ·
[XR sync policy](../platform/tenancy/chart/templates/control-plane.yaml) ·
[J4 lifecycle](journeys/j4-request-database.md)

## QA engineer

### Make the signed-image evidence mandatory and traceable

**Fix before closing Phase 3.** The checked-in journey fixtures still say
`PENDING_FIRST_CI_RUN`. The separate build workflow prints digests but the PR journey
job has no explicit handoff. The policy harness checks for a directory and trusts the
CLI's exit code. The pinned CLI returns zero for the image-admission directory with
no test YAML. Require real signed and unsigned fixtures, record the exact digest
and tested revision, and fail the required check when either outcome is missing.
[Fixture file](../tests/e2e/lib/images.env) · [Build workflow](../.github/workflows/build-hello.yaml) ·
[PR workflow](../.github/workflows/pr-checks.yaml) · [Policy harness](../scripts/test-policies.sh)

### Make the cross-tenant deny test fail when its target is absent

**Fix before claiming Argo application isolation.** O1 conditionally skips real team-b
application GET and sync requests if it finds no application. It also passes an empty
result from the list check. Create known applications in both projects, assert the
developer can see their own, then assert the foreign application is absent from a
successful list response and inaccessible through both direct operations.
[Argo isolation assertions](../tests/e2e/o1-onboard-team/argocd-deny.sh)

### Prove that network denial came from policy

**Fix on kind and extend before claiming AKS parity.** The suite treats any unsuccessful
probe as denied, including DNS, gateway, application, or destination failure. The named
cross-team target is not created by the suite. Use known healthy endpoints and positive
controls, then check transport denial specifically. For canary weighting, test both the route
configuration and traffic behavior. Separate portable tests from kind-specific hostnames,
CA setup, and component pins.
[Network contract assertions](../tests/e2e/network-contract/contract.sh) ·
[Kind client](../tests/e2e/lib/client.sh)

### Test cluster placement with distinct capabilities

**Add a split fixture before trusting the placement check.** The existing kind check counts
Applications and checks that selectors use a recognized capability key. A cluster labeled
for both capabilities can make swapped control-plane and workload selectors look correct.
Use separate simulated targets and assert exact destination per application, then prove
credential and CRD isolation on live split AKS.
[Placement assertions](../tests/e2e/placement/check-placement.sh) ·
[Cluster topology fitness checks](adr/0001-control-and-workload-cluster-split.md)

### Prove that the replacement Pod uses the rotated database credential

**Fix the J4 assertion.** The rotation test can see a new ReplicaSet and still query
an old ready Pod. The cleanup test also treats a failed API read like deletion. Wait for
the updated Deployment generation and a new ready Pod, query through it, and distinguish
an explicit NotFound from an API or authorization error during cleanup.
[J4 rotation and cleanup assertions](../tests/e2e/j4-request-database/lifecycle.sh)

### Report validation skips and profile coverage explicitly

**Fix the evidence summary before using CI as a release gate.** Static validation can
discard failed managed and BYO renders, ignore resources with missing schemas, and skip
composition renders when Docker is unavailable. Report which profile, resource, or
composition was skipped and why. Require the checks advertised for the active phase to
run and pass, and link the result to the tested revision and fixture digests.
[Static validation harness](../scripts/validate.sh) · [PR workflow](../.github/workflows/pr-checks.yaml)

## Security engineer

### Protect the signing job from caller-controlled shell input

**Fix before relying on the signer.** The reusable workflow substitutes the caller's image
name and GitHub ref into shell scripts. GitHub evaluates those expressions before the shell
runs, so shell quotes around the expressions do not provide an input boundary. This job has
package-write and signing permissions. Pass these values through environment variables, quote
them in the shell, validate the image name and context, and have a CI check guard against
direct interpolation in privileged scripts.
[Workflow source](../.github/workflows/reusable-build-sign.yaml) ·
[GitHub guidance on script injection](https://docs.github.com/en/actions/concepts/security/script-injections)

### Attest the base that the build actually used

**Fix before relying on the base-image claim.** The workflow verifies the Dockerfile's
`BASE_IMAGE` argument and attests that value. The caller's Dockerfile controls its stages
and can ignore that argument. The signed predicate therefore cannot establish that the
published image used that runtime base. Constrain the build recipe or validate actual build
materials before signing. State whether the policy also covers builder stages and verify
that a mismatched runtime base fails the build.
[Build and attestation workflow](../.github/workflows/reusable-build-sign.yaml) ·
[Dockerfile reference](https://docs.docker.com/reference/dockerfile/#from)

### Assign hostnames to tenants

**Fix before claiming tenant isolation.** A local Helm render of `hello` in `team-a-dev` and
`team-b-dev` produced the same `hello-dev.apps.kind.test` hostname. The chart also accepts a
host override, and the shared Gateway accepts routes from all team-labeled namespaces. Two
ordinary deployments can compete for the same hostname. Derive defaults using the tenant,
enforce host ownership, and prove that both same-name apps are reachable and that a foreign
host claim is rejected.
[Hostname helper](../charts/golden-service/templates/_helpers.tpl) ·
[Gateway template](../platform/components/platform-gateway/templates/gateway.yaml) ·
[Gateway API security guidance](https://gateway-api.sigs.k8s.io/docs/concepts/security/#avoiding-hostnamedomain-hijacking)

### Define the secret boundary within one team

**Fix or state the trust model before the AKS identity claim.** The kind vault reader can read
all keys for its team and environment. The chart takes a database dependency name from app
values and asks that reader to extract the key. Kubernetes API read denial for a developer
and cross-team denial for an ESO reader leave a different question open. Can a second app
in the same team request credentials for the first app's database through Git? Prove the
intended behavior and either bind approved dependencies to the consuming app or document
the shared team/environment trust boundary for kind. Prove with Entra that the app itself
can only access its authorized resources on AKS.
[Vault roles](../platform/tenancy/chart/templates/secrets.yaml) ·
[Dependency binding](../charts/golden-service/templates/dependencies.yaml) ·
[J4 isolation assertions](../tests/e2e/j4-request-database/lifecycle.sh)

### Keep local files out of the kind Git snapshot

**Fix before recommending bootstrap on arbitrary checkouts.** The seed script imports
unignored untracked files into a public in-cluster Gitea repository. Local files such as a
developer's environment config do not need to be part of a platform test. Seed from tracked
content and give unpublished additions an explicit path. Verify that a local-only file is
omitted and a tracked deletion is reflected in the snapshot.
[Gitea seed script](../infra/kind/gitea.sh)

### Treat GitHub administration as part of the trust boundary

**Define and prove before organization adoption.** Admission trusts workflow branches and tags
plus an allowlist of caller repository names and refs. State who may change the workflow,
tag, caller allowlist, and branch protection, and what happens when a repository is transferred
or renamed. Include required checks, permissions, workflow review, repo and project defaults,
and Renovate controls in the organization baseline. A separate issue is the image namespace.
The workflow publishes under the calling repo, while admission currently permits this
reference repo's GHCR prefix. Prove the intended flow with a real team-owned repository and
define how private images are pulled and verified.
[Signing workflow](../.github/workflows/reusable-build-sign.yaml) ·
[Admission policy](../platform/tenancy/chart/templates/policies.yaml) ·
[Allowed image prefixes](../platform/components/kyverno-policies/values.yaml)
