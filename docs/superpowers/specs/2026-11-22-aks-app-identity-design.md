# Phase 4 slice 2 application identity

**Status:** Draft for review. One app owns each Azure PostgreSQL request.

This slice proves that the sample app can use its own workload identity to query a private Azure PostgreSQL database on managed AKS. A second app in the same team must be able to get its own token and reach the database endpoint, then be denied by PostgreSQL. The existing cross-team, alternate ServiceAccount and cleanup checks in [ADR-0008](../../adr/0008-application-workload-identity.md) still apply. The [Phase 4 tracker](../../adr/README.md#phase-4-exit-criteria-tracker-d-087) defines the managed network gate.

## Ownership and lifecycle

Add a typed application reference to the PostgreSQL request. The reference is the app name in the same team and environment. The tenant namespace supplies the team, environment and workload group. Require the reference for Azure and preserve the existing kind request format and brokered credentials. Once set, the reference is immutable. A different app needs a new request and an explicit data migration.

The AppIdentity XR uses its name as the app name. Before rendering an Entra administration grant, its Azure composition must verify the referenced PostgreSQL request is in the same tenant namespace and names this app. An absent or mismatched reference yields no grant and an actionable reconcile status. Allowing an identity to nominate databases without a matching declaration on each request would leave ownership ambiguous. Keeping the declaration on the database request also gives reviewers one place to check ownership. This boundary assumes trusted reviewers for the team deploy repository, which can change both app declarations and database requests.

Use the control-plane EnvironmentConfig and Terraform's workload cluster output to resolve the issuers in the tenant's workload group. Derive the ServiceAccount subject from the tenant namespace and app name. The identity request cannot supply an issuer, subject, tenant, resource group or a raw Azure grant. If placement or owner inputs are missing, report them explicitly. Hold the last valid set of reconciled resources on a transient lookup failure. A confirmed removal from placement or from the app's declared dependencies must remove the corresponding credential or grant.

Build on the existing per-tenant ESO path for the app's client and tenant IDs. Names for app identity metadata and database connection metadata must be disjoint even when their request names match. The cloud chart profile projects a token for the app ServiceAccount and mounts it only in the app containers that need it. Keep managed and BYO app-facing renders equivalent for the same platform inputs. On kind, the local AppIdentity composition reports the existing password-based deviation.

Document and test the deletion order before enabling the Azure path. Drop the database grant before removing its identity or database, and verify that repeated cleanup handles resources already absent. The AKS teardown must drain AppIdentity XRs as well as PostgreSQL XRs before destroying Terraform foundations.

## Managed network path

Use the existing private DNS zone and delegated PostgreSQL subnet from Terraform. Add the managed Gateway profile and supply the approved app domain through platform values. Scope database egress to the delegated subnet and PostgreSQL port. Use the baseline HTTPS egress in D-086 for token exchange. Run the same Gateway API contract suite against the managed workload cluster, with the platform's ingress configuration supplied by the environment.

## Evidence required

| Check | Passing evidence |
| --- | --- |
| Offline composition cases | Valid owner renders one grant and only issuers in the selected group. Missing owner, wrong owner and missing placement render no new grants. A transient lookup failure preserves active resources. Confirmed removal prunes the corresponding grant or credential. |
| Chart and local behavior | Managed and BYO renders agree for equivalent inputs. Stable and canary use the intended ServiceAccount. Existing kind app requests and the password-based database journey still work. |
| Azure allow | The owning app exchanges its projected token and completes a query over the private database path. |
| Same-team wrong-app deny | A second app obtains a token as itself. With the same network reachability and database endpoint, PostgreSQL rejects the login. |
| Wrong-ServiceAccount deny | A different ServiceAccount in the owning namespace attempts to exchange its projected token for the owner's identity. Entra refuses the exchange, before the database is contacted. |
| Cross-team deny | Cross-team access fails. Record separately whether the network blocks the path or the connected database rejects the identity. |
| Lifecycle | Removing the app's requests removes its grant, federated credentials and identity. A teardown query against Azure verifies that the environment leaves no resources behind. |
| Managed ingress and networking | The Gateway API contract suite passes on managed AKS and the app responds on its approved HTTPS host. |

The live run depends on the cloud preflight and the owner's confirmation of the subscription, region, permissions, quota, budget, timeout and teardown owner. Azure provisioning is a separate operation after the design and implementation are ready.
