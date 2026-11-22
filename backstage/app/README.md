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
provider only works under `NODE_ENV=development`, and `app-config.production.yaml` has no provider and no demo data.

## Local data

| File | What it holds | Authority it stands in for |
| --- | --- | --- |
| `catalog/demo-entities.yaml` | Teams, demo users, the `hello` and `inventory` services and their declared environments | Reviewed service metadata in Git |
| `../../platform/tenancy/teams/*.yaml` (read, not copied) | Each team's deploy repository and approved environments | The platform's team definitions (ADR-0007, D-017) |
