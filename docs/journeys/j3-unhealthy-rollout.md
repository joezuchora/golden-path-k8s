# J3 An unhealthy rollout shows the next action

**Who:** an app team. **Promise:** P3 A way to see what it's doing; Developer Contract "Failure and recovery".
**Exit criterion 5.** **Suite:** `tests/e2e/j3-unhealthy-rollout/`.

## What happens

A developer merges a configuration mistake: the app is told to listen on port 9090 (`extraEnv: {PORT: "9090"}`), but
its probes check 8080. The image is valid and admitted; the rollout never becomes ready.

## What the developer sees

1. Argo CD marks `team-a-hello-dev` **Degraded** once the Deployment misses its progress deadline
   (`progressDeadlineSeconds`, golden-service value).
2. The merge commit gets a **failure** status: *Synced; health Degraded: … Next: scripts/idp-diagnose.sh hello dev --team
   team-a*. The suite runs that exact command from the status, with the developer's identity.
3. The developer runs the diagnosis with their own credentials (illustrative output; the suite asserts the step, the
   probe failure and the next action):

   ```text
   $ scripts/idp-diagnose.sh hello dev --team team-a
   STEP         STATUS  CURRENT STATE
   Sync         OK      Argo CD team-a-hello-dev: Succeeded
   Rollout      FAIL    0/1 ready; pods: NotReady; …; events: Unhealthy: Readiness probe failed: … connection refused
   Route        OK      https://hello-team-a-dev.apps.kind.test accepted by the platform gateway

   FAILED STEP: Rollout (FAIL)
   NEXT ACTION: Revert the PR, or fix and re-merge (for example the port, probe path or configuration in apps/hello/dev.yaml).
   ```

`idp-diagnose.sh` reads only the team's own namespaces (`<team>-<env>`, `tenant-<team>-<env>`) through the `view` role,
extended with the platform's read-only kinds (`platform-rbac`). The suite runs it as an impersonated team-a developer,
who has no cluster-scoped read access at all (O1), so the diagnosis provably needs none.

The steps it checks, in order: sync and admission (Argo CD, with the team's token), rollout, dependencies (XR and
ExternalSecret), route. For each failure it prints the current state and the next action from the contract's
failure table, including when the fix is a platform page rather than a PR.

## Where kind deviates

The developer identity is impersonated (D-050); on AKS it's the developer's Entra identity with the same RoleBindings.
