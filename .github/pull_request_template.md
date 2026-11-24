<!-- Definition of done: CLAUDE.md "Definition of done" (D-107). Paste evidence, not claims: the command and its result. -->

## What and why

<!-- What changes, and the problem it solves. One paragraph. -->

## Plan for substantial changes

<!-- Before editing, capture the outcome, the Developer Contract promise or repo invariant, the main risk, and the acceptance criteria. Flag any decision that needs the maintainer's input. -->

## Decision tracking

- D-entry: <!-- D-xxx added/updated in docs/adr/README.md, or "none: no design decision" -->
- ADR: <!-- docs/adr/NNNN-*.md, or "not needed" (no promise's tool, security boundary or costly-to-reverse change) -->
- Contract v1 surface touched (golden-service 1.x, XRD v1, reusable-build-sign@v1, Kyverno set v1): <!-- no / yes: minor or major (ADR-0010) -->

## Testing done

<!-- For each acceptance criterion, name the command or CI check and its observed result. Keep skipped or unavailable evidence under "Not covered". -->

```text
make quick-check        →
make validate           →
make test-policies      →   (policies touched)
make verify-docs        →   (docs touched)
make e2e JOURNEY=...    →   (journeys affected)
```

- Test that fails without this change: <!-- policy case, render golden file, Chainsaw step; or why none is possible -->
- Review: <!-- /code-review and the pr-reviewer subagent: findings fixed, or why not -->

## Not covered

<!-- What this PR does not prove (for example AKS-only behaviour pending live evidence), and where that is tracked. -->
