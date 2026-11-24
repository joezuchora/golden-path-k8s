# J5 Get an app identity

**Who:** an app team. **Promise:** P2 ("Your app reaches Azure services without a stored secret"). **Fitness check:**
ADR-0013's kind checks (D-104, D-105, D-109). **Suite:** `tests/e2e/j5-app-identity/`.

## What the developer does

1. PR on the deploy repo: `xrs/dev/hello-identity.yaml`

   ```yaml
   apiVersion: platform.example.org/v1
   kind: AppIdentity
   metadata: {name: hello}   # the name is the app
   spec: {}
   ```

2. PR on the deploy repo: opt in to the identity in the app's values, `identity: {enabled: true}`.

No issuer, subject, tenant, role or tag: the XRD has no such fields. The platform derives the issuer and subject from the
tenant namespace and the environment's clusters, so nothing the team writes can widen where the identity is trusted.

## What the platform does

```text
AppIdentity (tenant-team-a-dev) ─ composition "local" ─► federation record (issuer, subject, audience)
                                                       └► identity Secret + PushSecret ─► vault-team-a-dev
app namespace team-a-dev ◄── ExternalSecret hello-identity (golden-service) ◄──────────────┘
pod: ServiceAccount hello, projected token (audience api://AzureADTokenExchange), AZURE_* variables
```

| Step | Evidence the suite checks |
|---|---|
| 1. Declare | `AppIdentity` `Ready=True`; the federation record's subject is `system:serviceaccount:team-a-dev:hello`, derived from the namespace; the XR's status names the identity Secret; the IDs reach the team's vault under `appidentity-hello` |
| 2. Deliver | `hello-identity` synced into `team-a-dev` with the placeholder IDs; the pod runs as ServiceAccount `hello`; `AZURE_CLIENT_ID` comes from that Secret |
| 3. Match | The token the kubelet mounted in the pod, read from its node, matches the federation record: issuer, subject and audience, the three values Entra compares (F62); the token is bound to the pod |
| 4. Deny | A token for another ServiceAccount in the namespace, for team-b's same-named app, or for the Kubernetes API audience doesn't match. A TokenRequest for the app's own ServiceAccount and the record's audience does, as a control. Changing or removing a database's owning app (`PostgreSQLInstance.spec.app`) is rejected (D-102) |
| 5. Cleanup | Deleting the XR by PR removes the XR (no finalizers left), the federation record, the identity Secret, the PushSecret, the vault entry and the delivered Secret |

Another workload in the namespace can't run as `hello` to borrow the identity: `serviceaccount-matches-app` rejects a pod
whose ServiceAccount differs from its app label. Its pass and fail cases are in `make test-policies` (D-104).

## Where kind deviates

kind has no Microsoft Entra ID, so nothing exchanges the token, and the IDs are placeholders (`local`); that is ADR-0008's
one stated deviation. The suite proves everything up to the exchange: the token the app holds is the one a federated
credential built from the record would accept, and no other one is. On AKS the `azure` composition creates the
user-assigned identity and one federated credential per workload cluster from the same values (proven statically by its
render tests), and the release gate proves the exchange: the app's own query succeeds, and every deny holds.
