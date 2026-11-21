# require-controller

**What it checks.** A Pod created in a team namespace has an owning controller (`metadata.ownerReferences`), such as a
ReplicaSet or a Job.

**Why.** A bare Pod skips the rollout, health tracking and label inheritance that the platform applies per Deployment
(ADR-0007), and nothing recreates it when its node goes away.

**Fix.** Ship a Deployment through the golden-service chart, or a Job for one-off work.

**Tests.** `platform/policies/tests/require-controller/` covers a ReplicaSet-owned Pod (pass) and a bare Pod (fail).
