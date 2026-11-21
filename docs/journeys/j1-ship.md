# J1 Ship by merging a PR

**Who:** an app team. **Promise:** P4 A safe way to ship ("You ship by merging a pull request", F16) and P2 ("Your app
gets an HTTPS URL"). **Exit criterion 3.** **Suite:** `tests/e2e/j1-ship/`.

## What the developer does

1. Build the image: push to the app repo. `build-hello.yaml` calls `reusable-build-sign.yaml@v1`, which verifies the
   Chainguard base, builds, scans, signs keyless and attests the SBOM, the provenance and the base digest (ADR-0005).
2. Open a PR on the team's deploy repo that adds or changes `apps/<app>/<env>.yaml` (golden-service values):

   ```yaml
   app: hello
   env: dev
   image: ghcr.io/joezuchora/golden-path-k8s/hello@sha256:<digest printed by CI>
   ```

3. Merge it. Nobody runs `kubectl apply`.

## What the platform does

| Step | Component | Evidence the suite checks |
|---|---|---|
| Render | The team's ApplicationSet (tenancy, D-061) → Argo CD Application `<team>-<app>-<env>` with golden-service | Application `Synced` |
| Admit | Kyverno: signer + caller + verified base digest (D-026), resources, registry, derived labels (D-063) | Pod template carries `cost-center` from the team file; the running image is the signed digest |
| Roll out | Deployment, Pod Security `restricted` | Application `Healthy` |
| Route | HTTPRoute on the platform Gateway, cert from cert-manager (kind: platform CA, D-051) | `https://hello-team-a-dev.apps.kind.test/` returns 200 from an in-cluster client; HTTP returns 301; the response header modifier is present |
| Report | Argo CD notifications → Gitea commit status (D-043) | The merge commit has a `success` status from `platform/argocd/team-a-hello-dev-in-cluster` |

## Where kind deviates

The Git host is Gitea instead of GitHub, and the HTTPS certificate comes from a self-signed platform CA instead of ACME.
Routes are tested from inside the cluster, because Docker Desktop can't route to kind node IPs (F37).
