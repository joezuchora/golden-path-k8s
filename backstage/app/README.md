# Backstage: local dependency catalog preview

A local Backstage app (D-101) where a service owner requests a database for a service and environment, compares the
approved offerings, and previews the Git request the platform would review. Milestone 1 is a dry run only: it writes
nothing outside the Scaffolder workspace, opens no PR, and calls no cluster or cloud API. It runs with GitHub, Azure
and Kubernetes credentials absent.

Design: [dependency catalog spec](../../docs/superpowers/specs/2026-11-22-backstage-dependency-catalog-design.md);
sequence: [implementation plan](../../docs/superpowers/plans/2026-11-22-local-backstage-catalog.md).

## Prerequisites

| Tool | Version | Notes |
| --- | --- | --- |
| Node.js | 24.15+ or 26.13+ (`engines` in `package.json`) | Generated with `@backstage/create-app` 0.9.4 (Backstage release 1.57.0), which refuses Node 22. |
| Yarn | 4.13.0, pinned by `packageManager` and `.yarn/releases/` | Run `corepack enable` once, or use `.yarn/releases/yarn-4.13.0.cjs` directly. |

## Run it

From `backstage/app`:

```bash
yarn install --immutable
yarn tsc
yarn start                  # frontend http://localhost:3000, backend http://localhost:7007
```

Sign in with **Enter** (the local guest provider). The demo identity is `user:default/alice`, a member of
`group:default/team-a`, which owns `hello`. Team B's demo user is `bob` (owns `inventory`): put
`auth.providers.guest.userEntityRef: user:default/bob` in `app-config.local.yaml` (gitignored) and restart. The guest
module is registered only under `NODE_ENV=development` (`packages/backend/src/features.ts`). Backstage deep-merges
`app-config.production.yaml` over `app-config.yaml`, so the guest settings still appear in the merged config, but no
deployment loads the module that reads them.

## Local data

| File | What it holds | Authority it stands in for |
| --- | --- | --- |
| `catalog/demo-entities.yaml` | Teams, demo users, the `hello` and `inventory` services and their declared environments | Reviewed service metadata in Git |
| `../../platform/tenancy/teams/*.yaml` (read, not copied) | Each team's deploy repository and approved environments | The platform's team definitions (ADR-0007, D-017) |
| `packages/backend/src/dependencyCatalog/fixtures.yaml` | The approved offerings (shown in the form and enforced by the backend) and two placement profiles | Platform-owned offering and placement configuration (ADR-0014) |
| `catalog/request-database.yaml` | The database request template | The service-facing request form |

## Walkthrough: request a database

1. Open <http://localhost:3000/create>, choose **Request a database**, and sign in as the guest (alice, Team A).
2. **Service and environment.** Pick `hello`. The environment list shows only what the service declares and its team
   approves (`dev`).
3. **Database.** Keep the name `primary-db` and compare the two cards. Each shows the operating owner, the availability
   target and the cost assumptions. Both are **Preview: dry run only**, and every price is labeled **Illustrative
   estimate, not a quote**. HorizonDB shows its region and sizing inputs and says no regional rate is available.
   CloudNativePG separates allocated capacity from added node spend.
4. **Review**, then **Create**. The task output shows the path and the exact file. It also shows the owner, deploy
   repository and destination that the backend derived. For example:

   ```yaml
   # dependency-requests/dev/hello/primary-db.yaml
   version: 1
   service: hello
   environment: dev
   name: primary-db
   offering: azure-horizondb
   ```

To see a denial, start over and pick Team B's `inventory`. The task fails with "You cannot request dependencies for
"inventory"…" and writes no file. For a dry run that returns the workspace files, use the Template Editor
(**Create → Template Editor → Load Template Directory**, then choose `catalog/`). Scripts can call
`POST /api/scaffolder/v2/dry-run` directly.

## Dependency requests

`dependency:renderRequest` is the only step in the template. For every run, including dry runs, it:

1. Reads the initiator from the task's backend credentials, never from the form, and reads that user's team
   memberships from the catalog.
2. Accepts only `service`, `environment`, `name` and `offering`. It rejects any other field, including `owner`,
   `deployRepo`, `subscriptionId`, `credentials` and `token`. Each value must be a lowercase DNS label of at most 63
   characters that starts with a letter and isn't a YAML keyword such as `true`, `no` or `null`, so it reads back as
   a string.
3. Counts only services from the reviewed catalog files (`dependencyCatalog.reviewedServiceFiles`); a Component
   registered at runtime is treated as unknown. Checks that the caller's team owns the service, the environment is approved for both the service and the team, and
   the offering exists and is a database.
4. Resolves exactly one platform placement for (team, environment, offering). It fails closed when the placement is
   missing or ambiguous, names an unknown destination, or names a destination not approved for that team.
5. Writes `dependency-requests/<env>/<service>/<name>.yaml` inside the task workspace and nothing else. The file holds
   only the five logical fields, so retries produce identical bytes. It is the same file under both placement
   profiles.

| Rejection | HTTP status | Fix |
| --- | --- | --- |
| Another team's service, or a destination not approved for your team | 403 | Ask that team, or pick your team's service. For placement errors, the platform team fixes placement in Git. |
| Unknown field, platform-owned field, invalid name, unknown service, environment or offering, wrong capability, missing or ambiguous placement | 400 | Submit only the four fields with approved values. For placement errors, the platform team fixes placement in Git. |

**Placement profiles** (`dependencyCatalog.placementProfile` in `app-config.yaml`):

| Profile | Azure offering resolves to | In-cluster offering resolves to |
| --- | --- | --- |
| `sandbox` (default) | One placeholder subscription, a resource group per team (`rg-gp-team-a-dev`, `rg-gp-team-b-dev`) | The `shared` workload group |
| `enterprise` (simulated) | A separate landing-zone subscription per team | A platform-owned shared destination, workload group `shared-dev` |

Not in this milestone: PR publishing, provisioning, live prices, and validation of requests committed straight to Git.
Next is a PR publish step against a disposable or mocked Git repository. It needs a deterministic path, idempotent
retries, and a conflict when the same path gets different contents. See the
[plan](../../docs/superpowers/plans/2026-11-22-local-backstage-catalog.md).
