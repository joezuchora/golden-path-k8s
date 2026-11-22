# Backstage dependency catalog first slice

**Status:** Draft for review

**Date:** 2026-11-22

Give a service team a Backstage form to request a database for an existing service and environment. The form shows the approved offering, its operating owner, availability and cost assumptions. It renders a reviewable Git request. The initial milestone is a local dry run from the form to the rendered file.

## Scope and dependencies

Start with one database request template and two offering definitions. The approved directions are Azure HorizonDB and PostgreSQL on AKS through CloudNativePG. Both are visible in the local preview. Live requests remain disabled until the provisioning and security checks for the selected offering pass.

Keep the request shape reusable for object storage, shared files, cache, job queues and event streams. Add one capability at a time. Each defines its protocol, cost drivers and proof of isolation. Phase 4 continues to own AKS, identity, private networking and live qualification of backend integrations.

Before bootstrapping AKS, use the [deployment planning walkthrough](../../deployment-planning.md) to agree on owners, approval routes and approved destinations. The installer decides which foundations to create or reuse. Both choices use the same service-facing request.

## Request and placement

| Record | Authority |
| --- | --- |
| Service identity, team, owner and approved environments | Reviewed Git metadata. Backstage projects it in the catalog. |
| Offering definitions and release status | Platform-owned Git. An offering declares its interface, operating owner, availability and the assumptions behind its cost estimate. |
| Dependency request | The service deploy repository. The request identifies the service, environment, dependency name and logical offering. |
| Subscription, resource group and cluster placement | Platform-owned configuration. The local pilot resolves all Azure destinations to one configured sandbox subscription. Enterprise resolution can later use an existing or vended landing zone. |

The team member selects an existing service they are authorized to change and an environment the service declares. Derive the destination repository and ownership from reviewed metadata. Reject unknown offerings, unauthorized service IDs and unapproved environments on the backend. The form and the backend validator use the same offering data. Requests delivered directly through Git still pass the platform validation before a provisioning controller consumes them.

Render the proposed file under `dependency-requests/<env>/<service>/<name>.yaml`, outside the existing `xrs/<env>/` Argo CD sync path. It stays inert in the first milestone. Repeated dry runs with the same valid inputs produce the same file path and content. In the next milestone, reuse that path for a PR against the approved repository and reject a conflicting request for an existing dependency name.

For example, a dry run for `hello` writes `dependency-requests/dev/hello/primary-db.yaml`:

```yaml
version: 1
service: hello
environment: dev
name: primary-db
offering: azure-horizondb
```

## What the service owner sees

1. Select the service and environment.
2. Compare the managed and in-cluster options at the same availability target.
3. Review the requested name, owning service, operating owner and cost inputs before generating the request.
4. In local preview, inspect the exact path and generated file. Once the publish action is integrated, follow the PR and its review status.

For the managed choice, show region and service sizing as estimate inputs. For the in-cluster choice, show allocated compute and storage and any incremental node capacity separately. Show when a regional rate or availability estimate is unavailable. The first slice can use clearly labeled fixture data to exercise this presentation.

Use the Backstage Scaffolder's standard template form and dry-run support. Add the PR publish action after the dry run is covered. See [Backstage template configuration](https://backstage.io/docs/features/software-templates/configuration/) and [dry-run testing](https://backstage.io/docs/features/software-templates/dry-run-testing/).

## Acceptance checks

- Dry-run each database choice for the sample service and compare the generated request to the expected file.
- Reject an unsupported offering, an environment the service does not own, and a service the requester's identity cannot modify.
- Verify owner and repository selection come from the reviewed configuration. Verify a request cannot supply credentials, a raw subscription target or a repository override.
- Verify the dry run makes no GitHub, cluster or Azure writes.
- Before enabling a live offering, prove least-privilege access, a same-team wrong-app denial, private connectivity, restore and teardown on the target backend.
