# tenant-namespace-xrs-only

**What it checks.** Anything Argo CD syncs into a tenant namespace on the control plane (`tenant-<team>-<env>`) must be an
XR from `platform.example.org`, such as a `PostgreSQLInstance`. Pods, Deployments, Services, ConfigMaps, Secrets and the
like are rejected there. Objects the platform's own operators create in the namespace (for example the CloudNativePG
cluster's pods) aren't affected, because only requests from Argo CD's application controller are checked.

**Why.** Tenant namespaces hold your dependency requests next to the platform's credentials for them (D-024). Your app
runs in `<team>-<env>`, where image admission, the network baseline and the other app policies apply. The other app
policies deliberately don't cover tenant namespaces, so this policy keeps app workloads out of them.

**Fix.** In your deploy repo, `xrs/<env>/` holds only XRs. Move anything else into your app's golden-service values under
`apps/<app>/<env>.yaml`.

**Tests.** `platform/policies/tests/tenant-namespace-xrs-only/` covers an XR (pass), and a Deployment and a ConfigMap
(fail).
