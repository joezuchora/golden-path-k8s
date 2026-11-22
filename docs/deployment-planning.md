# Plan the deployment before bootstrap

Start with the teams that will own and operate the platform. Use this walkthrough to agree on who makes each decision and to collect the settings the installer needs. For the reference demo, one person can cover every role and one Azure subscription can host every team.

## 1. Agree on how the teams work together

Record an accountable group or contact for each role. Walk one request through intake, review, provisioning, support and retirement. Be able to say who approves it, who can access it, who pays for it and who gets paged.

| Role | Decide and record |
| --- | --- |
| Platform | Who owns Terraform, AKS, GitOps, the catalog and shared dependencies. Who can approve a platform change, operate the deployment pipeline and lead an incident. |
| Service | Which team owns each service, its deploy repository, environments and on-call contact. Who can approve changes, request a dependency and grant its use to another service. |
| Security | Which identity and data rules apply in each environment, who approves exceptions, how elevated access is granted and what evidence is required to enable an offering. |
| Network and DNS | Who approves regions, address space, private connectivity, DNS zones and ingress names. Which networks and operator egress IPs can reach the platform. |
| Billing and governance | Who owns the subscription and cost center, which landing-zone policies apply, who receives budget alerts, and who can approve added spend or create a subscription. |

## 2. Fill out the deployment worksheet

Keep the approved organization and placement metadata in Git. Use Backstage to display it and collect requests. Put credentials in the installer environment or the approved secret store.

| Collect | Demo path | Enterprise path |
| --- | --- | --- |
| Cloud destination | One existing subscription, one approved region, a short environment ID and an expiry date | Entra tenant, existing or vended subscription IDs, management group and approved regions for each platform or workload destination. Record the billing scope if vending is in use. |
| Owners and identity | One platform contact and one or two example teams. Replace the example developer groups with actual Entra group object IDs for AKS. | Platform, security, network, billing and workload groups, with scoped access and escalation contacts. Record deployment and runtime identities separately. |
| Service registration | One team owns `hello` in `dev`. Record the deploy repository and approved caller refs, workload group, quota, cost center and data classification. | Record the same fields per team, then map each service environment and approved offering to its destination. Capture any approved cross-team access separately. |
| Network and policy | Operator API-server CIDRs and the sandbox address space. Record the approved app hostname if the exercise uses HTTPS ingress. | Network ownership, hub and spokes, address reservations, private DNS, ingress, egress, applicable policy baseline, and the exception or approval route. |
| Cost and lifecycle | One budget contact, alert thresholds, a teardown owner, expiry and an agreed time for cleanup verification | Budget and cost center per landing zone, allocation for shared services, approved regions and quotas, retention and restore obligations, and owners for decommissioning and verification. |

Copy this worksheet once for the demo or once per approved destination in an enterprise deployment.

```text
Service, owning team and on-call:
Environment, deploy repository and approved refs:
Platform owner, security reviewer, network reviewer and billing contact:
Entra tenant and approved developer, deployment and runtime identities:
Destination alias, subscription ID, management group and allowed regions:
Workload group, network ranges, private DNS and ingress hostname:
Data classification, policies and approved dependency offerings:
Cost center, budget, alert recipients and shared-cost allocation:
Quota, retention and restore targets, teardown owner and expiry:
```

## 3. Walk through one request

**Demo example.** The installer acts as platform operator, security reviewer and billing contact. Team A owns `hello` in `dev` and deploys to the `shared` workload group. Team B can exercise a second ownership boundary. Both teams use one existing subscription. Set `subscription_id` once in the [sandbox Terraform example](../infra/envs/sandbox/sandbox.tfvars.example). Set the team owners, Entra group IDs, cost centers, and approved environments using the [sample team definition](../platform/tenancy/teams/team-a.yaml). For the Azure deploy repositories, confirm `GP_DEPLOY_REPO_TEMPLATE` in the [bootstrap script](../infra/aks/aks.sh).

**Enterprise example.** A fictional company runs a platform AKS fleet, with shared messaging operated by its platform on-call. The Payments service team has separate development and production landing zones. The team requests a production database for `checkout-api` and a stream for order events.

| Destination alias | Owner | Example placement and handoff |
| --- | --- | --- |
| `platform-aks` | Cloud Platform | Platform subscription for AKS and GitOps. Network Operations reviews private DNS and the paths from workload clusters to approved endpoints. |
| `payments-dev` | Payments | Existing nonproduction subscription. Payments owns retention and on-call and bills to its nonproduction cost center. |
| `payments-prod` | Payments | Separate production landing zone. The platform resolves the database request here. Security reviews the approved data classification and access policy. Payments owns the database's application usage and restore requirement. |
| `platform-messaging-prod` | Cloud Platform | Shared messaging subscription. The platform team operates the broker. Payments owns its stream and approves authorized consumers. FinOps records Payments' allocation and any additional capacity. |

The service team selects its service, environment and offering. The approved Git metadata supplies owner, repository and destination. Reviewers can trace the request to the applicable security policy, cost center and pager before it is provisioned. Use the example to review the operating model. The reference Terraform setup takes one subscription ID, and the multi-subscription mappings describe the enterprise adoption path.

## 4. Hand off to the installer

Check that someone can name the owner, target environment, approved access and budget for the example request. For the demo, copy the sandbox Terraform example, replace its placeholder values, review the team definitions, then return to the [AKS preflight and bootstrap steps](getting-started.md#4-cloud-aks-phase-4). For an enterprise installation, use the completed worksheet to register the approved landing zones and establish the platform's review and provisioning responsibilities.
