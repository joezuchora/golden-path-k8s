# require-resources

**What it checks.** Every container and init container declares a CPU request, a memory request and a memory limit. It
applies to Pods and to the pod templates of Deployments, StatefulSets, DaemonSets, Jobs and CronJobs. A missing value
fails the Argo CD sync of your PR, instead of surfacing later as a pod that never schedules.

**Why.** Without requests, the scheduler can overcommit nodes. Without a memory limit, one app can starve its neighbours.
Your namespace's ResourceQuota also counts requests and limits.

**Fix.** Set them in your golden-service values:

```yaml
resources:
  requests: {cpu: 50m, memory: 64Mi}
  limits: {memory: 128Mi}
```

The golden-service chart sets defaults. This policy fires when they're removed, or when a manifest bypasses the chart.

**Tests.** `platform/policies/tests/require-resources/` covers complete resources (pass), a Deployment without a memory
limit (fail) and a Pod without requests (fail).
