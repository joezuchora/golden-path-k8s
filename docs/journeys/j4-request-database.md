# J4 Request a database

**Who:** an app team. **Promise:** P1 ("You can request an environment"; self-service dependencies) and P2.
**Exit criterion 6** (XR lifecycle including app connection, rotation and cleanup, D-024). **Suite:**
`tests/e2e/j4-request-database/`.

## What the developer does

1. PR on the deploy repo: `xrs/dev/orders-db.yaml`

   ```yaml
   apiVersion: platform.example.org/v1
   kind: PostgreSQLInstance
   metadata: {name: orders-db}
   spec: {storageGB: 1}
   ```

2. PR on the deploy repo: declare it in the app's values, `dependencies: {postgres: [orders-db]}`.

No tags, owner or cost center: the XRD has no such fields (D-017). The composition derives them from the tenant
namespace.

## What the platform does

```text
XR (tenant-team-a-dev) ─ composition "local" ─► CloudNativePG Cluster + PushSecret ─► vault-team-a-dev (kind's Key Vault)
                                                                                        │ SecretStore "platform"
                       app namespace team-a-dev ◄── ExternalSecret (golden-service) ◄───┘
```

| ADR-0002 step | Evidence the suite checks |
|---|---|
| 1. XR Ready | `PostgreSQLInstance` `Ready=True`; the composed Cluster carries the derived `cost-center` |
| 2. ExternalSecret synced | `hello-orders-db-db` Ready in `team-a-dev`; team-b's reader can't read team-a's vault; developers can't read either secret |
| 3. Real query | `/readyz` through the HTTPS route returns *ready (database query ok)*: the readiness probe connects with the brokered credential and runs `select 1` |
| 4. Rotation | The password in the source Secret changes → it reaches the app namespace → Reloader restarts the Deployment → `/readyz` passes with the new credential |
| 5. Cleanup | Deleting the XR by PR removes the XR (no finalizers left), the Cluster and its volumes, the vault secret (`deletionPolicy: Delete`) and the delivered secret |

## Where kind deviates

The `local` composition uses CloudNativePG (D-053) and a password; the vault is a namespace (D-064). On AKS the `azure`
composition creates a Flexible Server with Entra authentication only (ADR-0008), and the vault is Key Vault. The XR, the
store names and the app's values are identical. The `azure` composition is proven statically in Phase 3
(`crossplane resource validate` + a render golden file) and live in Phase 4.
