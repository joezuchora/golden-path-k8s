# Journeys

A journey is something an app team or the platform team does, end to end, through the platform's interfaces: Git, the
golden-service chart, XRs and read-only diagnostics. Each journey has a page here and a Chainsaw suite in `tests/e2e/`
with the same name (CLAUDE.md invariant, checked by `make validate`). Every suite runs on kind on every PR (D-047).

| Journey | Who | Contract promise | Exit criterion (Phase 3) | Suite |
|---|---|---|---|---|
| [J1 Ship by merging a PR](j1-ship.md) | App team | P4, P2 | 3 | `make e2e JOURNEY=j1-ship` |
| [J2 A rejected change tells you how to fix it](j2-rejected-change.md) | App team | P4 | 4 | `make e2e JOURNEY=j2-rejected-change` |
| [J3 An unhealthy rollout shows the next action](j3-unhealthy-rollout.md) | App team | P3 | 5 | `make e2e JOURNEY=j3-unhealthy-rollout` |
| [J4 Request a database](j4-request-database.md) | App team | P1, P2 | 6 | `make e2e JOURNEY=j4-request-database` |
| [J5 Get an app identity](j5-app-identity.md) | App team | P2 | ADR-0013 kind checks | `make e2e JOURNEY=j5-app-identity` |
| [O1 Onboard a team](o1-onboard-team.md) | Platform team + app team | P1, P3 | 7 | `make e2e JOURNEY=o1-onboard-team` |

Platform checks (not journeys) have suites too: `placement` (exit criterion 1, D-023) and `network-contract` (contract
P1/P2, ADR-0003). `make test-policies` covers exit criterion 2.

**On kind** the Git host is an in-cluster Gitea (D-043): suites open and merge real PRs through its API, exactly as a
developer would, and read the commit status Argo CD writes back. Identities are kind substitutes (D-050): Kubernetes
impersonation of team groups, and Argo CD local accounts bound to AppProject roles. Images are the CI-built fixtures in
`tests/e2e/lib/images.env` (D-059).
