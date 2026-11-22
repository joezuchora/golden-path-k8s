# Local Backstage dependency catalog implementation plan

> Implement task by task with the executing-plans skill. Use the checkboxes to record completed work.

**Goal:** A service owner can choose either database offering in local Backstage and preview the Git request without cloud credentials.

**Architecture:** Backstage presents platform-owned offering data and submits a logical request. A backend validator uses the trusted caller identity and reviewed service metadata, resolves a destination from installer configuration, and writes a deterministic file to the Scaffolder workspace.

**Tech stack:** Backstage Scaffolder, TypeScript, YAML, Yarn, and local SQLite for the disposable Backstage development instance. kind is needed only for the follow-on cluster exercises.

**Spec:** [Backstage dependency catalog design](../specs/2026-11-22-backstage-dependency-catalog-design.md)

## Global constraints

- Work in the catalog worktree. Compare with current main at implementation kickoff and read the [deployment planning walkthrough](../../deployment-planning.md). Phase 4 owns live AKS and backend qualification.
- The first flow is a local preview. A task can write only its Scaffolder workspace. It does not publish a PR, update a cluster, or call Azure.
- Both database choices use approved fixture data. Do not show real-looking prices as live rates or advertise an unqualified backend as ready.
- Resolve identity and ownership from trusted backend context and Git metadata. Forms never provide a caller identity, owner, repository, credentials, subscription, or cluster ID.
- Keep one set of offering data for form choices, cost presentation and backend validation. Keep new files under the existing planned Backstage workspace unless modifying an existing CI or setup entry point.

## Planned files and boundaries

The following is the proposed layout. Keep the generated Backstage app structure and add only the files needed for the preview.

```text
backstage/app/
  app-config.yaml                                  Local app and catalog locations
  catalog/demo-entities.yaml                       Sample services and ownership
  catalog/request-database.yaml                    Scaffolder template
  packages/backend/src/index.ts                     Wire the dependency Scaffolder module
  packages/backend/src/dependencyCatalog/
    model.ts                                       Request, offering and placement types
    fixtures.yaml                                  Offerings and illustrative placement profiles
    resolve.ts                                     Authorization and placement checks
    resolve.test.ts
    render.ts                                      Deterministic path and file contents
    render.test.ts
    module.ts                                      Register the Scaffolder action
    module.test.ts
  packages/app/src/dependencyCatalog/
    OfferingPicker.tsx                             Present approved choices and estimate inputs
    OfferingPicker.test.tsx
```

## Review focus

| Failure mode | Expected result | Task |
| --- | --- | --- |
| Caller uses the UI or API to select a different team's service | Backend denies the request before resolving a destination | 2, 3 |
| More than one destination matches, or placement targets another team | Fail closed and do not render a file | 2 |
| A path component or extra field attempts to override the reviewed request | Reject the input before writing | 2 |
| Cost or availability data is absent or illustrative | UI identifies unavailable data and labels fixtures | 4 |
| Repeated dry run or same dependency name with changed contents | Identical request path and bytes for retries. A future PR publisher reports a conflict for changed contents. | 2, 5 |

## Milestone 1: Local database request and placement

### Task 1: Start the Backstage development app

- [ ] Scaffold the app at `backstage/app` using the [standalone setup](https://backstage.io/docs/getting-started/). Verify the generator's supported runtime, record the resolved scaffolder version, and commit the package manager pin and lockfile.
- [ ] Configure local catalog registration for fixture services `hello` and `inventory` with distinct owning groups. Keep the local demo identity separate from any deployment authentication configuration.
- [ ] From `backstage/app`, run `yarn install --immutable`, `yarn tsc`, and `yarn start`. Verify the catalog lists the two services and the Scaffolder opens without cloud or GitHub credentials.
- [ ] Commit the runnable local app and its setup notes.

### Task 2: Resolve and render requests

The resolver consumes strict form input and a trusted caller, then returns the approved owner, repository and destination internally. The renderer emits only the logical request.

```ts
type DependencyInput = {
  service: string;
  environment: string;
  name: string;
  offering: string;
};
type Caller = { groupRefs: readonly string[] };
type ResolvedRequest = {
  input: DependencyInput;
  ownerRef: string;
  deployRepo: string;
  destinationRef: string;
};
type RenderedRequest = { path: string; contents: string };
type CatalogConfig = {
  services: readonly {
    id: string; ownerRef: string; deployRepo: string; environments: readonly string[];
  }[];
  offerings: readonly {
    id: string;
    capability: 'database' | 'cache';
    mode: 'managed' | 'in-cluster';
    operatingOwner: string;
    availability: string;
    cost?: {
      basis: 'illustrative';
      inputs: readonly string[];
      allocatedMonthly?: number;
      incrementalMonthly?: number;
      currency?: string;
    };
  }[];
  placements: readonly {
    service: string; environment: string; offering: string; destinationRef: string;
  }[];
  destinations: readonly {
    ref: string; approvedOwners: readonly string[];
    subscriptionId?: string; workloadGroup?: string;
  }[];
};
// resolveRequest(raw: unknown, caller: Caller, config: CatalogConfig, capability: 'database' | 'cache'): ResolvedRequest
// renderRequest(resolved: ResolvedRequest): RenderedRequest
```

- [ ] Write resolver tests using a Team A caller, Team B caller, two services, and a sandbox and enterprise placement fixture. Assert Azure requests from two authorized teams resolve to one configured subscription in the demo. In the enterprise fixture, resolve the same logical request to an approved landing zone and resolve CloudNativePG to the selected workload group. Test unknown offering, unauthorized caller, wrong environment, wrong-owner target, missing placement and duplicate matching placement.
- [ ] Write renderer tests for `hello/dev/primary-db` with each offering. Assert the exact path and parsed YAML in the design. Repeating a request must produce identical bytes. Reject uppercase, path traversal, separators, unknown keys and platform-owned fields. Pass the template capability to the resolver from backend registration, so a database template cannot submit a different kind of offering. Accept only lowercase DNS-style segments of up to 63 characters in file path components.
- [ ] Run `yarn backstage-cli repo test --watch=false` from the app and verify the new tests fail before the functions exist.
- [ ] Implement strict parsing, membership and environment checks, and a single approved match for `service + environment + offering`. For the simulated enterprise profile, ensure the matched destination authorizes the owner or is explicitly approved for that owner as a shared destination. Emit the five fields from the spec using stable field order. Keep Azure and platform coordinates out of the rendered request.
- [ ] Rerun tests and `yarn tsc`, then commit the resolver, renderer, and fixtures.

### Task 3: Wire the local Scaffolder action

- [ ] Write an action test with an authorized task initiator and a mocked workspace. Assert it writes the resolved request once. Repeat with a Team B initiator and credentials, owner, or subscription overrides in form input, and assert zero writes on reject.
- [ ] Register `dependency:renderRequest` with dry-run support. Read the task initiator from backend credentials, resolve their trusted group membership, then invoke the validator and renderer. Write only within the task workspace. Give dry runs a distinct result that reports the generated path.
- [ ] Register the database template with four fields from `DependencyInput` and that single action. Register no live PR publishing action for this milestone. Use [Scaffolder dry-run guidance](https://backstage.io/docs/features/software-templates/dry-run-testing/).
- [ ] Run the action test and `yarn tsc`. Run both sample requests through the local Template Editor and inspect the file results. Commit the action and template.

### Task 4: Show the choice, operating owner, and cost assumptions

- [ ] Add UI tests for HorizonDB and CloudNativePG option cards, including ownership, availability, labeled sample pricing, and missing pricing. Verify the in-cluster choice distinguishes allocated capacity from added node spend.
- [ ] Read the same approved offering list as the backend. Display a region and sizing assumption for managed offerings and resource and incremental capacity assumptions for in-cluster offerings. Keep selection limited to the service's allowed environment and the offering list. The backend repeats the authorization and input checks.
- [ ] Run UI tests and `yarn tsc`. Capture the two dry-run results and one rejected request as evidence with the commit SHA. Commit the UI and local walkthrough.

### Task 5: Review and automate the local checks

- [ ] Use the repository's existing PR checks as the CI entry point. Add a Backstage-path check that installs from the lockfile, validates app configuration, type-checks, and runs backend and UI tests. Preserve the existing static and kind behavior.
- [ ] Verify on a clean checkout that the two requests produce the expected files and the denial cases leave no output, with Azure, Kubernetes, and GitHub credentials absent. Run `make verify-docs` and the Backstage check.
- [ ] Confirm the local proof uses no live integration. The next increment is a PR publish test against a disposable or mocked Git repository with a deterministic request path, idempotent retries, and a conflict on different contents at the same path. Check that direct Git requests get equivalent platform validation before adding any provisioning adapter.

## Follow-on work specs

Each row is a separate deliverable. The local database request and placement milestone establishes the request shape. Nothing in this table requires an Azure deployment.

| Work | Proposed change | Local acceptance and prerequisites |
| --- | --- | --- |
| Cache catalog | Add Azure Managed Redis and Valkey to platform-owned offering data. Use one cache per service and environment. Managed Redis is the production default, and the Valkey preview compares standalone and HA operating assumptions. | After tasks 2–4, render one cache request per choice using the same contract. Compare cost inputs and fixture labeling, deny a service-owner mismatch, and confirm a database template cannot submit a cache offering. A later backend proof exercises warm hits, empty-cache fallback, and isolation. |
| Second-team onboarding on kind | Extend the existing O1 onboarding journey for a second team, reusing the J4 database lifecycle where needed. Exercise reviewed team metadata and GitOps, then document any existing helper still required. | Coordinate access to the shared kind cluster. Run `make e2e JOURNEY=o1-onboard-team` and `make e2e JOURNEY=j4-request-database`. Capture allowed same-team work, cross-team Kubernetes and Argo CD denial, and cleanup. |
| First language golden path | Start with Go and reuse the `hello` build and chart contract for a generated service. Constrain the first slice to one template, one health endpoint and the existing signing workflow. | Render into a temporary repo and run `go test ./...`, then lint the rendered chart. Use the existing signed-fixture CI path and kind to prove a signed generated image deploys and a rejected image produces actionable feedback. |
| Brownfield and enterprise configuration checks | Add independent fixtures for a platform-owned shared destination, a workload landing zone, and an existing network or registry reference. Keep creation and adoption behavior explicit in the platform configuration. | Exercise logical resolution on local inputs and test that a reference-only resource cannot enter a teardown plan. Actual network or registry integration is qualified through Phase 4 or a separate rollout. |

Local completion establishes the catalog request, authorization and repeatable Git output. On Azure, each offering still needs live evidence for private access, identity, wrong-service denial, recovery and teardown before activation.
