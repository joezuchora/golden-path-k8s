#!/usr/bin/env bash
# quick-check.sh: `make quick-check` and the Claude Code Stop hook (D-107). Fast checks scoped to the change against the
# merge base with origin/main (committed, uncommitted and untracked files). It complements `make validate` and
# `make test-policies`, which stay the full gates in CI: this runs in seconds, so an agent can't end a turn with an
# invariant broken in the files it touched. Tested by tests/scripts/quick-check-test.sh.
#
#   bash scripts/quick-check.sh          report PASS/FAIL; exit 1 on a failure
#   bash scripts/quick-check.sh --hook   Claude Code Stop hook: on a failure, exit 2 with the reasons on stderr, so Claude
#                                        keeps working. Once per turn: when Claude is already continuing because of this
#                                        hook (stop_hook_active), it shows the failures to the user and lets the turn end.
#
# A missing tool skips its check (it never blocks). To turn the hook off, start Claude Code with GP_QUICK_CHECK=off, or set
# it under "env" in .claude/settings.local.json.
set -uo pipefail
here="${BASH_SOURCE[0]}"
command -v cygpath >/dev/null 2>&1 && here="$(cygpath -u "$here")"   # a Windows path (CLAUDE_PROJECT_DIR) has backslashes
ROOT="$(git -C "$(dirname "$here")" rev-parse --show-toplevel)" || exit 0
cd "$ROOT"
# A worktree (D-089) has no ./.bin of its own until make tools runs there; fall back to the main checkout's.
main_bin="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)/.bin"
export PATH="$ROOT/.bin:$main_bin:$PATH"
hook=0; again=0
if [ "${1:-}" = --hook ]; then
  hook=1; input="$(cat)"
  [ "${GP_QUICK_CHECK:-}" = off ] && exit 0
  tr -d ' \r\n' <<<"$input" | grep -qF '"stop_hook_active":true' && again=1
fi

fails=(); notes=()
fail() { fails+=("$*"); }
note() { notes+=("$*"); }
have() { command -v "$1" >/dev/null 2>&1; }

base="$(git merge-base HEAD origin/main 2>/dev/null)" || { [ "$hook" = 1 ] && exit 0; echo "SKIP  no origin/main to compare with"; exit 0; }
mapfile -t changed < <({ git diff --name-only --diff-filter=d "$base" 2>/dev/null; git ls-files --others --exclude-standard; } | tr -d '\r' | sort -u)
[ "${#changed[@]}" -eq 0 ] && { [ "$hook" = 1 ] || echo "PASS  no changes against origin/main"; exit 0; }
has() { printf '%s\n' "${changed[@]}" | grep -E "$1" >/dev/null; }   # not grep -q: an early exit breaks the pipe (pipefail)
list() { printf '%s\n' "${changed[@]}" | grep -E "$1" || true; }

# Secret and state files, by name (CLAUDE.md "File Handling", .gitignore). File contents aren't scanned.
bad="$(list '(^|/)\.env$|\.tfstate|\.auto\.tfvars$|settings\.local\.json$|(^|/)tfplan' | tr '\n' ' ')"
[ -z "$bad" ] || fail "secret or local state files in the change: $bad. Fix: remove them; they belong in .gitignore'd files only."

# Decision tracking (CLAUDE.md "Decision tracking"): an ADR or design-evolution change comes with its Decision Log entry.
if has '^docs/adr/[0-9]{4}-.*\.md$|^docs/design-evolution\.md$' && ! has '^docs/adr/README\.md$'; then
  fail "ADR or design-evolution changed without docs/adr/README.md. Fix: add or update the D-entry (date, options, rationale, AKS-native alternative, status)."
fi
row_ids() { tr -d '\r' | grep -oE '^\| [DF]-?[0-9]{1,3} \|' | tr -d '| ' | sort -u; }
if has '^docs/adr/README\.md$'; then
  dups="$(tr -d '\r' <docs/adr/README.md | grep -oE '^\| [DF]-?[0-9]{1,3} \|' | sort | uniq -d | tr -d '| ' | tr '\n' ' ')"
  [ -z "$dups" ] || fail "duplicate Decision Log / F-table IDs: $dups. Fix: take the next free ID."
  # Parallel agents (D-089) claim IDs on their own branches. An ID this change adds (not one it only edits, such as a
  # Revisited mark) mustn't have a row or a reservation on any other branch of origin, main included, as of the last fetch.
  new="$(comm -13 <(git show "$base:docs/adr/README.md" 2>/dev/null | row_ids) <(row_ids <docs/adr/README.md))"
  if [ -n "$new" ]; then
    skip="$(printf '%s\n' origin origin/HEAD "origin/$(git symbolic-ref --short -q HEAD)" \
      "$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)")"
    mapfile -t refs < <(git for-each-ref --format='%(refname:short)' refs/remotes/origin | grep -vxF "$skip")
    # One git grep over every ref (a process per ref costs about a second each on Windows); awk prints "<id> <ref>".
    while read -r id r; do
      fail "$id is already claimed on $r. Fix: run git fetch --prune, then take an ID free on every branch and in every Reserved D-IDs line."
    done < <([ "${#refs[@]}" -gt 0 ] && git grep -E '^(\| [DF]-?[0-9]{1,3} \||Reserved D-IDs)' "${refs[@]}" -- docs/adr/README.md 2>/dev/null \
      | tr -d '\r' | sed 's/–/-/g' | awk -v new="$(echo $new)" '
        BEGIN { n = split(new, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 }
        { i = index($0, ":docs/adr/README.md:"); ref = substr($0, 1, i - 1); line = substr($0, i + 20)
          if (line ~ /^\| /) { split(line, c, " "); if (c[2] in want) print c[2], ref; next }
          while (match(line, /D-[0-9][0-9][0-9](-+D-[0-9][0-9][0-9])?/)) {
            r = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH)
            lo = substr(r, 3, 3) + 0; hi = substr(r, length(r) - 2) + 0
            for (k = lo; k <= hi; k++) { id = sprintf("D-%03d", k); if (id in want) print id, ref }
          } }' | sort -u | awk '{ refs[$1] = ($1 in refs ? refs[$1] ", " : "") $2 } END { for (i in refs) print i, refs[i] }')
  fi
fi

# Every journey has an e2e suite (CLAUDE.md "Invariants").
while IFS= read -r j; do
  id="$(basename "$j" .md)"; [ "$id" = README ] && continue
  [ -d "tests/e2e/$id" ] || fail "journey $id has no tests/e2e/$id. Fix: add the Chainsaw suite in the same change."
done < <(list '^docs/journeys/[^/]+\.md$')

# Kyverno: every touched policy test directory has both a pass and a fail case (CLAUDE.md "Kyverno").
while IFS= read -r d; do
  [ -n "$d" ] || continue
  [ -f "$d/kyverno-test.yaml" ] || { fail "$d has no kyverno-test.yaml"; continue; }
  grep -qE 'result: *pass' "$d/kyverno-test.yaml" && grep -qE 'result: *fail' "$d/kyverno-test.yaml" \
    || fail "$d/kyverno-test.yaml needs both a pass and a fail result. Fix: add the missing case."
done < <(list '^platform/policies/tests/[^/.][^/]*/' | cut -d/ -f1-4 | sort -u)
has '^platform/(policies|components/kyverno-policies|tenancy/chart/templates)/' \
  && note "policies changed: run make test-policies before the PR (online: GHCR + Rekor)"

# Images: every image this change adds is digest-pinned (CLAUDE.md "Images"): image: values (block or inline YAML), FROM
# and *_IMAGE build args in Dockerfiles. Templated values are left to make validate, which checks the rendered output.
# Policy and e2e fixtures are excluded: a fail case may need an unpinned image on purpose.
added() { # every line the change adds in the given pathspecs, as "+line"; the whole content of untracked files
  local x=(':(exclude)*.md' ':(exclude)docs/**' ':(exclude)platform/policies/tests/**' ':(exclude)tests/e2e/**')
  git diff "$base" -U0 -- "$@" "${x[@]}" 2>/dev/null | grep -E '^\+' | grep -vE '^\+\+\+ '
  git ls-files --others --exclude-standard -z -- "$@" "${x[@]}" | xargs -0r sed 's/^/+/' 2>/dev/null
}
dockerfiles=(':(glob)**/Dockerfile*' ':(glob)**/Containerfile*')
img="$({ added '*.yaml' '*.yml' '*.json' | grep -vE '^\+[[:space:]]*#' \
           | grep -oE '(^\+|[{,[:space:]])"?image"?:[[:space:]]*["'\'']?[a-z0-9][^"'\'',}[:space:]]*'
         added "${dockerfiles[@]}" | grep -E '^\+FROM[[:space:]]+[^$[:space:]]*[./:]'
         added "${dockerfiles[@]}" | grep -E '^\+ARG[[:space:]]+[A-Z_]*IMAGE=.'; } \
  | tr -d '\r' | grep -vE '@sha256:[0-9a-f]{64}|\{\{|\$\{' || true)"
[ -z "$img" ] || fail "unpinned image references added: $(echo "$img" | head -5 | tr -s ' \n' ' '). Fix: pin as <ref>@sha256:<digest> (Chainguard :latest@sha256 for bases)."

# Workflows: remote actions pinned by SHA; no ${{ }} inside run: (D-069).
while IFS= read -r f; do
  [ -f "$f" ] || continue
  u="$(grep -E '^\s*(- )?uses: ' "$f" | grep -vE 'uses: \./' | grep -vE '@[0-9a-f]{40}( |$)' || true)"
  [ -z "$u" ] || fail "$f: actions not pinned by commit SHA: $(echo "$u" | tr -s ' \n' ' ')"
  if have yq; then
    inj="$(yq -r '.jobs[].steps[]? | select(.run != null) | .run' "$f" 2>/dev/null | grep -c '\${{' || true)"
    [ "${inj:-0}" = 0 ] || fail "$f: \${{ }} inside a run: script. Fix: pass the value through env: (D-069)."
  fi
done < <(list '^\.github/workflows/.*\.ya?ml$')

# Syntax: shell scripts parse; plain YAML parses (Helm templates aren't YAML).
while IFS= read -r f; do [ -f "$f" ] && { bash -n "$f" 2>/dev/null || fail "$f: bash -n fails"; }; done < <(list '\.sh$')
if have yq; then
  while IFS= read -r f; do
    [ -f "$f" ] && { yq '.' "$f" >/dev/null 2>&1 || fail "$f doesn't parse as YAML"; }
  done < <(list '\.ya?ml$' | grep -v '/templates/')
else note "yq not found (run make tools): YAML parse check skipped"; fi

# Line endings: the index stores LF (CRLF working copies, autocrlf). A CRLF or mixed blob rewrites whole files in diffs.
crlf="$(printf '%s\0' "${changed[@]}" | xargs -0r git ls-files --eol -- 2>/dev/null | awk '$1 ~ /^i\/(crlf|mixed)$/ {print $NF}' | tr '\n' ' ')"
[ -z "$crlf" ] || fail "CRLF in the index: $crlf. Fix: git add --renormalize <file> (or rewrite with LF)."

# Repo coordinates only via render-repo-coords.sh (D-046): its --check rule, on the changed files in its scope.
repo="$(sed -n 's/^REPO=//p' repo-coords.env | tr -d '\r"')"
coords="$(list '^(platform|charts|\.github|apps|scripts|infra|tests|tools|docs/policies|docs/journeys)/|^docs/getting-started\.md$|^Makefile$' \
  | while IFS= read -r f; do [ -f "$f" ] && printf '%s\0' "$f"; done \
  | xargs -0r grep -IHnoE '(github\.com|ghcr\.io)/[A-Za-z0-9-]+/golden-path-k8s' 2>/dev/null | grep -v "/$repo" || true)"
[ -z "$coords" ] || fail "repo coordinates that don't match repo-coords.env ($repo): $(echo "$coords" | head -3 | tr '\n' ' '). Fix: scripts/render-repo-coords.sh."

# Helm lint for touched charts (same arguments as validate.sh).
if have helm && have yq; then
  while IFS= read -r c; do
    [ -f "$c/Chart.yaml" ] || continue
    if [ "$(yq '.dependencies // [] | length' "$c/Chart.yaml" 2>/dev/null)" != 0 ] && [ ! -d "$c/charts" ]; then
      note "$c: dependencies not fetched; helm lint left to make validate"; continue
    fi
    args=(); [ -f "$c/values-kind.yaml" ] && args+=(-f "$c/values-kind.yaml")
    case "$c" in
      charts/golden-service) args+=(-f charts/golden-service/ci/full-values.yaml --namespace team-a-dev) ;;
      platform/tenancy/chart) args+=(-f platform/tenancy/teams/team-a.yaml --set capability=workloads) ;;
    esac
    o="$(helm lint "$c" "${args[@]}" 2>&1)" || fail "helm lint $c: $(echo "$o" | grep -E 'ERROR|Error' | head -2 | tr '\n' ' ')"
  done < <(list '^(charts/[^/]+|platform/tenancy/chart|platform/components/[^/]+)/' \
           | sed -E 's#^(charts/[^/]+|platform/tenancy/chart|platform/components/[^/]+)/.*#\1#' | sort -u)
elif has '^(charts|platform)/'; then note "helm or yq not found (run make tools): helm lint skipped"; fi

# Terraform formatting for touched roots and modules.
if has '\.tf$'; then
  if have terraform; then
    while IFS= read -r d; do
      terraform fmt -check "$d" >/dev/null 2>&1 || fail "terraform fmt: $d. Fix: terraform fmt $d"
    done < <(list '\.tf$' | while IFS= read -r f; do dirname "$f"; done | sort -u)
  else note "terraform not found (run make tools): fmt check skipped"; fi
fi

# Report.
if ! printf '%s\n' "${changed[@]}" | grep -vE '\.md$' >/dev/null; then note "Markdown only: run make verify-docs before the PR"
else note "before the PR: make validate (and make test-policies / make e2e JOURNEY=<dir> for what you touched)"; fi
if [ "$hook" = 1 ]; then
  [ "${#fails[@]}" -eq 0 ] && exit 0
  msg="$(printf 'quick-check (D-107) found %d problem(s) in this change:\n' "${#fails[@]}"; printf -- '- %s\n' "${fails[@]}")"
  if [ "$again" = 1 ]; then   # second stop this turn: tell the user, don't block again
    if have jq; then jq -cn --arg m "$msg" '{systemMessage: $m}'; else echo "$msg" >&2; fi
    exit 0
  fi
  printf '%s\nFix them before finishing, or say in your reply why they must stay (the hook then lets you stop).\n' "$msg" >&2
  exit 2
fi
for n in "${notes[@]}"; do echo "NOTE  $n"; done
for f in "${fails[@]}"; do echo "FAIL  $f"; done
echo "quick-check: ${#changed[@]} changed file(s), ${#fails[@]} failed"
[ "${#fails[@]}" -eq 0 ]
