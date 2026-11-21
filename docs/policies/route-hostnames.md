# route-hostnames

**What it checks.** Every `HTTPRoute` in an app namespace lists at least one hostname, and the first label of each one
ends with `-<namespace>`. For `team-a-dev` that means hosts like `hello-team-a-dev.apps.kind.test`.

**Why.** All apps share the platform Gateway. Without ownership, two teams' apps with the same name would get the same
default host, and any team could set `route.host` to another team's URL and take its traffic. This is the hostname
hijacking risk the Gateway API security guidance describes. A route with no hostname is rejected too: it would match
every host on the listener.

**Fix.** Leave `route.host` unset in your golden-service values; the chart's default is `<app>-<team>-<env>.<domain>`.
If you need a different first label, keep the `-<team>-<env>` suffix.

**Tests.** `platform/policies/tests/route-hostnames/` covers the team's own host (pass), another team's host (fail) and a
route with no hostname (fail).
