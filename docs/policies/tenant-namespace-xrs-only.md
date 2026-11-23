# tenant-namespace-xrs-only

**What it checks.** Anything Argo CD syncs into a tenant namespace on the control plane (`tenant-<team>-<env>`) must be an
XR from `platform.example.org`, such as a `PostgreSQLInstance`. Every other kind, from any API group, is rejected there:
Pods, Deployments, ConfigMaps and Secrets, and also raw Crossplane managed resources (`*.azure.m.upbound.io`) and
CloudNativePG `Cluster`s (D-094). Objects the platform's own operators create in the namespace (for example the
resources Crossplane composes, or the CloudNativePG cluster's pods) aren't affected, because only requests from Argo CD's
application controller, for a team's XR application, are checked.

**Why.** Tenant namespaces hold your dependency requests next to the platform's credentials for them (D-024). Your app
runs in `<team>-<env>`, where image admission, the network baseline and the other app policies apply. The other app
policies deliberately don't cover tenant namespaces, so this policy keeps app workloads out of them. It's an allow list
because a deny list misses new kinds. A raw managed resource bypasses the XR API's limits and derived tags; before
D-099 it also ran on a provider configuration that could reach every tenant's resource group. Since D-099 Crossplane uses
only the tenant's own credentials in a tenant namespace, so this policy is the first of two layers, not the only one.

**Also checked.** A `PostgreSQLInstance` can't be named `appidentity-<anything>`: the team's secret store keeps
each app's identity metadata under that prefix (D-104).

**Fix.** In your deploy repo, `xrs/<env>/` holds only XRs. Move anything else into your app's golden-service values under
`apps/<app>/<env>.yaml`.

**Tests.** `platform/policies/tests/tenant-namespace-xrs-only/` covers an XR (pass); a Deployment, a ConfigMap, an Azure
`FederatedIdentityCredential` and `FlexibleServer`, and a CloudNativePG `Cluster` (fail); an `AppIdentity` (pass) and a
`PostgreSQLInstance` named `appidentity-hello` (fail); and the platform's own render
(skip). On kind, J2 cases (b) and (d) merge a Deployment and a CloudNativePG `Cluster` into `xrs/dev/` and check both
are denied with an actionable commit status.
