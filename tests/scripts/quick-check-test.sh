#!/usr/bin/env bash
# quick-check-test.sh: tests for scripts/quick-check.sh (D-107), run by the static CI job. Each case starts from a clean
# scratch clone whose origin/main is the current commit, makes one change and checks the verdict: every check must catch
# its violation (red) and must not fire on the look-alikes an agent writes every day (green), because a false positive in
# the Stop hook sends the agent back to work on something it can't fix.
set -euo pipefail
ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
main_bin="$(cd "$(git -C "$ROOT" rev-parse --git-common-dir)/.." && pwd)/.bin"
export PATH="$ROOT/.bin:$main_bin:$PATH"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
R="$T/repo"

src="$ROOT"; command -v cygpath >/dev/null && src="/$(cygpath -m "$ROOT")"   # file:///C:/... on Windows
git clone -q --depth 1 "file://$src" "$R" 2>/dev/null   # works from CI's shallow checkout too
cp "$ROOT/scripts/quick-check.sh" "$R/scripts/quick-check.sh"   # the version under test, committed or not
cd "$R"
git config user.email test@example.invalid; git config user.name quick-check-test; git config core.autocrlf false; git config core.eol lf
git add -A; git commit -qm baseline --allow-empty
for r in $(git for-each-ref --format='%(refname)' refs/remotes/origin); do git update-ref -d "$r"; done
git update-ref refs/remotes/origin/main HEAD
row="$(grep -m1 -E '^\| D-[0-9]{3} \|' docs/adr/README.md)"   # a real Decision Log row to copy

pass=0; fails=0
reset() { git reset -q --hard HEAD; git clean -qfd; for r in $(git for-each-ref --format='%(refname)' refs/remotes/origin); do
  [ "$r" = refs/remotes/origin/main ] || git update-ref -d "$r"; done; }
# expect <fail|pass> <name> [<pattern in the output>]: run quick-check on the working tree as it is now.
expect() {
  local want="$1" name="$2" pat="${3:-}" out rc=0
  out="$(bash scripts/quick-check.sh 2>&1)" || rc=$?
  if { [ "$want" = fail ] && [ "$rc" -ne 0 ] && grep -qF -- "$pat" <<<"$out"; } || { [ "$want" = pass ] && [ "$rc" -eq 0 ]; }; then
    pass=$((pass + 1)); echo "ok    $name"
  else
    fails=$((fails + 1)); echo "FAIL  $name (want $want${pat:+ with '$pat'}, exit $rc)"; echo "$out" | sed 's/^/        /'
  fi
  reset
}

expect pass "no changes"

# Decision tracking
echo x >>"$(ls docs/adr/0[0-9][0-9][0-9]-*.md | head -1)";               expect fail "ADR without its log row" "without docs/adr/README.md"
echo "$row" >>docs/adr/README.md;                                         expect fail "duplicate D-ID" "duplicate Decision Log"
f3="$(grep -m1 -E '^\| F[0-9] \|' docs/adr/README.md || true)"
if [ -n "$f3" ]; then echo "$f3" >>docs/adr/README.md;                    expect fail "duplicate single-digit F-ID" "duplicate Decision Log"; fi
sed -i '0,/^| D-[0-9]\{3\} |/s/| Accepted |/| Accepted (edited) |/' docs/adr/README.md
git switch -q -c other; git commit -qam other; git update-ref refs/remotes/origin/other HEAD; git switch -q -; git branch -qD other
sed -i '0,/^| D-[0-9]\{3\} |/s/| Accepted |/| Accepted (edited) |/' docs/adr/README.md
                                                                          expect pass "editing a row (Revisited) isn't a claim"
add_row() { printf '| %s | 2026-01-01 | test | - | - | - | Proposed | — |\n' "$1" >>docs/adr/README.md; }
git switch -q -c other; add_row D-998; git commit -qam other; git update-ref refs/remotes/origin/other HEAD; git switch -q -; git branch -qD other
add_row D-998;                                                            expect fail "ID claimed on another branch" "D-998 is already claimed on origin/other"
git switch -q -c mine; add_row D-997; git commit -qam mine; git update-ref refs/remotes/origin/mine HEAD
                                                                          expect pass "own pushed branch isn't a competing claim"
git switch -q -; git branch -qD mine
reserved="$(grep -m1 -oE '^Reserved D-IDs: D-[0-9]{3}' docs/adr/README.md | grep -oE 'D-[0-9]{3}' || true)"
if [ -n "$reserved" ] && ! grep -qE "^\| $reserved \|" docs/adr/README.md; then
  add_row "$reserved";                                                    expect fail "ID reserved on main" "$reserved is already claimed on origin/main"
fi

# Journeys and policies
echo "# j9" >docs/journeys/j9-test.md;                                    expect fail "journey without e2e suite" "journey j9-test has no tests/e2e/j9-test"
mkdir -p platform/policies/tests/zz; printf 'results:\n  - {policy: p, resources: [a], kind: Pod, result: pass}\n' >platform/policies/tests/zz/kyverno-test.yaml
                                                                          expect fail "policy test without a fail case" "needs both a pass and a fail"

# Images
printf 'spec:\n  - image: ghcr.io/foo/bar:1.0\n' >scripts/zz.yaml;              expect fail "unpinned image (block YAML)" "unpinned image"
printf 'canary: {replicas: 1, image: "ghcr.io/foo/bar:1.0"}\n' >scripts/zz.yaml;  expect fail "unpinned image (inline YAML)" "unpinned image"
printf 'image: nginx:1.29\n' >scripts/zz.yaml;                                    expect fail "unpinned Docker Hub short name" "unpinned image"
mkdir -p apps/zz; printf 'FROM alpine:3\n' >apps/zz/Dockerfile;                   expect fail "unpinned FROM" "unpinned image"
mkdir -p apps/zz; printf 'ARG BASE_IMAGE=cgr.dev/chainguard/static:latest\n' >apps/zz/Dockerfile; expect fail "unpinned base ARG" "unpinned image"
d="sha256:$(printf '%064d' 0)"
printf 'image: ghcr.io/foo/bar:1.0@%s\nimage: "{{ .Values.image }}"\n# image: ghcr.io/x/y:1\n' "$d" >scripts/zz.yaml
mkdir -p apps/zz; printf 'ARG BASE_IMAGE=cgr.dev/chainguard/static:latest@%s\nFROM ${BASE_IMAGE} AS base\nFROM base\nFROM scratch\n' "$d" >apps/zz/Dockerfile
printf '#!/usr/bin/env bash\n# image: ghcr.io/x/y:1\npsql -c "SELECT 1\nFROM pg_roles"\n' >scripts/zz.sh
mkdir -p tests/e2e/zz platform/policies/tests/zz; printf 'image: ghcr.io/foo/bar:1.0\n' | tee tests/e2e/zz/x.yaml >platform/policies/tests/zz/resources.yaml
printf 'results:\n  - {result: pass}\n  - {result: fail}\n' >platform/policies/tests/zz/kyverno-test.yaml
                                                                          expect pass "pinned, templated, stage, scratch, SQL, comments and fixtures"

# Workflows, syntax, files
mkdir -p .github/workflows; printf 'name: t\non: push\njobs:\n  a:\n    runs-on: x\n    steps:\n      - uses: actions/checkout@v4\n' >.github/workflows/zz.yaml
                                                                          expect fail "action not pinned by SHA" "not pinned by commit SHA"
if command -v yq >/dev/null; then
  printf 'name: t\non: push\njobs:\n  a:\n    runs-on: x\n    steps:\n      - run: echo ${{ github.head_ref }}\n' >.github/workflows/zz.yaml
                                                                          expect fail "\${{ }} in run:" "inside a run: script"
  printf 'a: [1, 2\n' >scripts/zz.yaml;                                   expect fail "invalid YAML" "doesn't parse as YAML"
  : >scripts/zz.yaml;                                                     expect pass "empty YAML"
fi
printf 'if then\n' >scripts/zz.sh;                                        expect fail "shell syntax error" "bash -n fails"
touch .env;                                                               expect fail "secret file by name" "secret or local state"
printf 'a: 1\r\n' >scripts/zz.yaml; git add scripts/zz.yaml; git update-index --add --cacheinfo "100644,$(git hash-object -w --no-filters scripts/zz.yaml),scripts/zz.yaml"
                                                                          expect fail "CRLF in the index" "CRLF in the index"
printf '# ghcr.io/%s/golden-path-k8s/x\n' someone-else >scripts/zz.sh;   expect fail "foreign repo coordinates" "repo coordinates"
mkdir -p docs/journeys; echo "# x" >"docs/journeys/a b.md";               expect fail "path with a space" "journey a b has no tests/e2e/a b"
if command -v helm >/dev/null && command -v yq >/dev/null; then
  sed -i 's/^name:.*/name: /' charts/golden-service/Chart.yaml;           expect fail "helm lint" "helm lint charts/golden-service"
fi
if command -v terraform >/dev/null; then
  printf 'locals {\nx=1\n}\n' >>"$(ls infra/envs/*/*.tf | head -1)";      expect fail "terraform fmt" "terraform fmt"
fi

# Hook mode (the Claude Code Stop hook)
hook() { local rc=0; echo "$1" | bash "$2" --hook >"$T/out" 2>"$T/err" || rc=$?; echo "$rc"; }
hk="$R/scripts/quick-check.sh"; command -v cygpath >/dev/null && hk="$(cygpath -w "$hk")"   # Windows: the path Claude Code passes
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"; else fails=$((fails + 1)); echo "FAIL  $1: got $2, want $3"; cat "$T/err"; fi; }
check "hook, clean: exit 0" "$(cd / && hook '{"stop_hook_active":false}' "$hk")" 0
echo x >>"$(ls docs/adr/0[0-9][0-9][0-9]-*.md | head -1)"
check "hook, failure: exit 2" "$(cd / && hook '{"stop_hook_active":false}' "$hk")" 2
check "hook, failure: reason on stderr" "$(grep -c 'without docs/adr/README.md' "$T/err")" 1
check "hook, second stop: exit 0" "$(cd / && hook '{"stop_hook_active": true}' "$hk")" 0
check "hook, second stop: failures shown" "$(cat "$T/out" "$T/err" | grep -c 'without docs/adr/README.md')" 1
check "hook, GP_QUICK_CHECK=off: exit 0" "$(cd / && GP_QUICK_CHECK=off hook '{}' "$hk")" 0
reset

echo "quick-check-test: $pass passed, $fails failed"
[ "$fails" -eq 0 ]
