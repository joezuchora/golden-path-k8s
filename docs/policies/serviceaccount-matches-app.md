# serviceaccount-matches-app

**What it checks.** A Pod in a team namespace, or a workload's pod template, runs as the ServiceAccount named after its
app: `spec.serviceAccountName` equals the `platform.example.org/app` label. A pod with no app label, or with no
ServiceAccount (Kubernetes then uses `default`), is rejected too.

**Why.** An app's cloud identity is federated to exactly one ServiceAccount, `system:serviceaccount:<team>-<env>:<app>`
(ADR-0008, ADR-0013). Microsoft Entra refuses a token from any other ServiceAccount, but a pod that names the app's
ServiceAccount gets the app's token. This policy stops another workload in the same namespace from borrowing an app's
identity that way (D-104).

**Fix.** Deploy through the golden-service chart, which sets the ServiceAccount and the app label from the same `app:`
value. To run a second component with its own identity, give it its own app and its own `AppIdentity`.

**Tests.** `platform/policies/tests/serviceaccount-matches-app/` covers a pod on its own app's ServiceAccount (pass), a
pod on another app's ServiceAccount, a pod on `default` and a pod with no app label (fail), and the same pass and fail
cases on Deployments, where Kyverno applies the policy to the pod template.
