#!/usr/bin/env bash
# verify-docs.sh: the Phase 2 documentation gate (D-035). It seeds Phase 6's decision-log-check.
#
# Checks:
#   1 mapping     README matrix: each component has exactly one promise (P1-P4) and canonical CNCF domains (F18);
#                 each component is listed under that domain in the coverage map; all 13 domains have a status;
#                 every ADR header uses canonical domain names.
#   2 citations   every F-, D- and ADR- reference resolves; every external URL in README, the contract and the
#                 frameworks docs matches an F-entry source; contract v1 states the D-027 network set and the
#                 D-022 identity promise.
#   3 links       relative links and anchors resolve; external URLs answer 2xx/3xx (skip with OFFLINE=1);
#                 429, 5xx and timeouts are retried with backoff before they fail (D-106).
#   4 mermaid     every ```mermaid block renders with a pinned mermaid-cli. If the CLI can't run, the result is
#                 UNVERIFIED, which fails the gate.
#   6 references  every repo path and `make` target named in a current doc exists (history docs are excluded).
#   5 log         D-IDs are unique and ascending, with gaps only inside a "Reserved D-IDs" line; every "Revisited → D-x" target exists and the revisited decision
#                 is in design-evolution.md; the ADR files and the ADR index match one to one.
#
# Usage: bash scripts/verify-docs.sh        (Git Bash, WSL, Linux, macOS; needs python3 or python, plus curl and npx)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
MERMAID_CLI="@mermaid-js/mermaid-cli@12.2.0"

PY="$(command -v python3 || true)"
if [ -z "$PY" ] || ! "$PY" -c 'import sys' >/dev/null 2>&1; then PY="$(command -v python || true)"; fi
if [ -z "$PY" ]; then echo "FAIL: python3 or python is required"; exit 2; fi

status=0

# Checks 1, 2, 3 (relative links) and 5 run in Python, since Markdown tables are fragile in awk.
# It prints the external URLs on lines starting with "URL " for the curl step.
py_out="$("$PY" - <<'PY'
import os, re, sys, glob

ROOT = os.getcwd()
CANON = [
    "Web portals for provisioning and observing capabilities",
    "APIs for automatically provisioning capabilities",
    "Golden path templates and docs",
    "Automation for building and testing products",
    "Automation for delivering and verifying services",
    "Development environments",
    "Application observability",
    "Infrastructure services",
    "Data services",
    "Messaging and event services",
    "Identity and secret services",
    "Security services",
    "Artifact storage",
]
STATUSES = ("Designed", "Proven", "Partial", "**Deferred**", "Deferred")

def read(p):
    with open(os.path.join(ROOT, p), encoding="utf-8") as f:
        return f.read()

def section(text, heading):
    m = re.search(r"^## " + re.escape(heading) + r"\s*$(.*?)(?=^## |\Z)", text, re.M | re.S)
    return m.group(1) if m else ""

def cells(line):
    return [c.strip() for c in line.strip().strip("|").split("|")]

results = {}
def report(check, errors):
    results[check] = errors

md_files = sorted(set(glob.glob("*.md") + glob.glob("docs/**/*.md", recursive=True)))
md_files = [f.replace("\\", "/") for f in md_files if f != "CLAUDE.md"]
log = read("docs/adr/README.md")
f_ids = set(re.findall(r"^\| (F\d+) \|", log, re.M))
d_rows = re.findall(r"^\| (D-\d{3}) \|", log, re.M)
d_ids = set(d_rows)

# ---- 1 mapping
errs = []
readme = read("README.md")
cov = read("docs/frameworks/cncf-capability-coverage.md")
matrix = [l for l in section(readme, "Developer Contract Matrix").splitlines() if re.match(r"^\| P[1-4] ", l)]
if len(matrix) < 20:
    errs.append(f"README matrix has only {len(matrix)} component rows")
cov_rows = {}
for l in section(cov, "Domains").splitlines():
    c = cells(l)
    if len(c) >= 5 and c[0].isdigit():
        cov_rows[c[1]] = (l, c)
for d in CANON:
    if d not in cov_rows:
        errs.append(f"coverage map is missing domain: {d}")
    elif not cov_rows[d][1][4].startswith(STATUSES):
        errs.append(f"coverage map domain has no valid status: {d}")
extra = set(cov_rows) - set(CANON)
for d in extra:
    errs.append(f"coverage map has a non-canonical domain: {d}")
seen = set()
for l in matrix:
    c = cells(l)
    if len(c) != 5:
        errs.append(f"matrix row doesn't have 5 columns: {l[:80]}")
        continue
    promise, comp, why, alt, dom = c
    if len(re.findall(r"\bP[1-4]\b", promise)) != 1:
        errs.append(f"component doesn't have exactly one promise: {comp}")
    if comp in seen:
        errs.append(f"duplicate component: {comp}")
    seen.add(comp)
    doms = [x.strip() for x in dom.split(";")]
    for x in doms:
        if x not in CANON:
            errs.append(f"non-canonical domain '{x}' for component: {comp}")
        elif comp not in cov_rows.get(x, ("", []))[0]:
            errs.append(f"component not listed under '{x}' in the coverage map: {comp}")
    if not re.search(r"\b(D-\d{3}|ADR-\d{4}|F\d+)\b", why):
        errs.append(f"'Why chosen' cites no decision or fact: {comp}")
    if not alt:
        errs.append(f"empty AKS-native trade-off: {comp}")
summary = [cells(l) for l in section(readme, "CNCF capability-domain coverage").splitlines() if re.match(r"^\| \d+ \|", l)]
if sorted(s[1] for s in summary) != sorted(CANON):
    errs.append("README coverage summary doesn't list exactly the 13 canonical domains")
for p in [x.replace("\\", "/") for x in sorted(glob.glob("docs/adr/[0-9][0-9][0-9][0-9]-*.md"))] + ["docs/adr/template.md"]:
    m = re.search(r"^- \*\*CNCF capability domain\(s\):\*\* (.+)$", read(p), re.M)
    if not m:
        errs.append(f"{p}: no CNCF domain header")
        continue
    v = m.group(1)
    if v.startswith("All") or v.startswith("<"):
        continue
    for x in [s.strip() for s in v.split(";")]:
        if x not in CANON:
            errs.append(f"{p}: non-canonical domain '{x}'")
report(f"1 mapping ({len(matrix)} components, {len(CANON)} domains, ADR headers)", errs)

# ---- 2 citations
errs = []
for p in md_files:
    t = read(p)
    for f in sorted(set(re.findall(r"(?<![A-Za-z0-9-])F\d+\b", t))):
        if f not in f_ids:
            errs.append(f"{p}: {f} has no F-table row")
    cited = re.sub(r"^Reserved D-IDs.*$", "", t, flags=re.M)  # a reservation names IDs that have no row yet (check 5)
    for d in sorted(set(re.findall(r"\bD-\d{3}\b", cited))):
        if d not in d_ids:
            errs.append(f"{p}: {d} has no Decision Log row")
    for a in sorted(set(re.findall(r"\bADR-(\d{4})\b", t))):
        if not glob.glob(f"docs/adr/{a}-*.md"):
            errs.append(f"{p}: ADR-{a} has no file")
def norm(u):
    u = re.sub(r"^https?://", "", u).split("#")[0].rstrip("/")
    return u.replace("/en-us/", "/")
f_section = log[log.index("## Verified facts"):]
f_sources = norm(f_section)
f_urls = [norm(u) for u in re.findall(r"https?://[^\s)|]+", f_section)]
for p in ["README.md", "docs/developer-contract.md"] + sorted(glob.glob("docs/frameworks/*.md")):
    for u in re.findall(r"\]\((https?://[^)\s]+)\)", read(p)):
        n = norm(u)
        if not any(n == fu or n.startswith(fu) for fu in f_urls):
            errs.append(f"{p}: external source not backed by an F-entry URL: {u}")
contract = read("docs/developer-contract.md")
for needle, why in [("D-027", "network feature set decision"), ("Gateway API v1.6.1", "pinned Gateway API"),
                    ("Promised route features (v1)", "route features"), ("Envoy Gateway v1.9.0", "pinned Envoy Gateway"),
                    ("Cilium v1.20.0", "pinned Cilium"), ("D-022", "identity decision"),
                    ("per app per environment", "identity promise"), ("Where kind deviates", "kind deviation"),
                    ("Version** | 1.0", "contract version")]:
    if needle not in contract:
        errs.append(f"developer-contract.md is missing the {why} ('{needle}')")
report(f"2 citations ({len(f_ids)} F-entries, {len(d_ids)} D-entries)", errs)

# ---- 3 relative links and anchors
def slug(h):
    h = re.sub(r"[`*_]", "", h.strip().lower())
    h = re.sub(r"\]\([^)]*\)", "", h).replace("[", "")
    h = re.sub(r"[^\w\- ]", "", h)
    return h.replace(" ", "-")
def anchors(p):
    out = set()
    in_code = False
    for line in read(p).splitlines():
        if line.startswith("```"):
            in_code = not in_code
        if not in_code:
            m = re.match(r"^#{1,6} (.+)$", line)
            if m:
                out.add(slug(m.group(1)))
    return out
errs = []
ext = set()
nrel = 0
for p in md_files:
    t = re.sub(r"```.*?```", "", read(p), flags=re.S)
    for link in re.findall(r"\]\(([^)\s]+)\)", t):
        if link.startswith(("http://", "https://")):
            ext.add(link)
            continue
        if link.startswith("mailto:"):
            continue
        nrel += 1
        path, _, frag = link.partition("#")
        target = os.path.normpath(os.path.join(os.path.dirname(p), path)) if path else p
        if not os.path.exists(target):
            errs.append(f"{p}: broken link {link}")
        elif frag and target.endswith(".md") and frag not in anchors(target):
            errs.append(f"{p}: missing anchor #{frag} in {target}")
report(f"3 links: relative ({nrel} links)", errs)

# ---- 5 log integrity
errs = []
nums = [int(d[2:]) for d in d_rows]
if len(nums) != len(set(nums)):
    errs.append("duplicate D-IDs")
# Parallel work claims ID ranges up front ("Reserved D-IDs: D-078–D-088 (Phase 4)") so two branches never take the same
# number. A gap is allowed only inside a declared reservation, and IDs must still be ascending.
reserved = set()
for line in re.findall(r"^Reserved D-IDs.*$", log, re.M):
    for lo, hi in re.findall(r"D-(\d{3})\s*[–-]\s*D-(\d{3})", line):
        reserved |= set(range(int(lo), int(hi) + 1))
    for one in re.findall(r"D-(\d{3})(?!\s*[–-])", line):
        reserved.add(int(one))
if nums != sorted(nums):
    errs.append("D-IDs are not in ascending order")
missing = sorted(set(range(1, max(nums) + 1)) - set(nums) - reserved) if nums else []
if missing:
    errs.append("D-IDs have gaps that no reservation covers: " + ", ".join(f"D-{m:03d}" for m in missing))
evo = read("docs/design-evolution.md")
for row in re.findall(r"^\| (D-\d{3}) \|(.*)$", log, re.M):
    for tgt in re.findall(r"Revisited → (D-\d{3})", row[1]):
        if tgt not in d_ids:
            errs.append(f"{row[0]} is revisited by a missing {tgt}")
        if row[0] not in evo:
            errs.append(f"{row[0]} is revisited but isn't in design-evolution.md")
fnums = [int(f[1:]) for f in re.findall(r"^\| (F\d+) \|", log, re.M)]
if fnums != list(range(1, len(fnums) + 1)):
    errs.append("F-IDs are not sequential from F1")
files = {os.path.basename(p)[:4] for p in glob.glob("docs/adr/[0-9][0-9][0-9][0-9]-*.md")}
idx = set(re.findall(r"^\| \[(\d{4})\]\((\d{4}-[^)]+\.md)\)", log, re.M))
idx_ids = {i for i, _ in idx}
for i, f in idx:
    if not os.path.exists(os.path.join("docs/adr", f)):
        errs.append(f"index row {i} points to a missing file {f}")
for i in sorted(files - idx_ids):
    errs.append(f"ADR {i} has no index row")
for i in sorted(idx_ids - files):
    errs.append(f"index row {i} has no ADR file")
report(f"5 log integrity ({len(nums)} decisions, {len(fnums)} facts, {len(files)} ADRs)", errs)

# ---- 6 repo references
# Current docs must describe the repo as it is: every repo path and `make` target they name must exist. History (ADRs,
# design-evolution, the dated platform review) is excluded, and so is any line about a later phase.
errs = []
current = [f for f in md_files if not (f.startswith("docs/adr/") or f in ("docs/design-evolution.md", "docs/platform-review.md"))]
roots = ("platform/", "charts/", "infra/", "tests/", "scripts/", "tools/", "apps/", "docs/", ".github/")
mk = read("Makefile")
targets = set(re.findall(r"^([a-z0-9][a-z0-9-]*):", mk, re.M))
npath = ntarget = 0
for f in current:
    fence = False
    for ln, line in enumerate(read(f).splitlines(), 1):
        if line.lstrip().startswith("```"):
            fence = not fence
            continue
        if re.search(r"Phase [4-9]|arrives in|planned|Planned", line):
            continue
        for tok in re.findall(r"`([^`\s]+)`", line):
            tok = tok.rstrip(".,;:)")
            if tok.startswith("platform/argocd/"):
                continue  # a commit-status context (platform/argocd/<application>), not a path
            if tok.startswith(roots) or tok in ("Makefile", "repo-coords.env", "ROADMAP.md", "CLAUDE.md"):
                if re.search(r"[<>*{}$|]", tok):
                    continue  # a pattern or placeholder, not a path
                npath += 1
                if not os.path.exists(tok.split("#")[0].rstrip("/") or "."):
                    errs.append(f"{f}:{ln}: names `{tok}`, which doesn't exist")
        # make targets: only inside backticks or code blocks, where they are commands rather than prose.
        cmds = re.findall(r"`make ([a-z0-9][a-z0-9-]*)[^`]*`", line)
        if fence:
            cmds += re.findall(r"^\s*make ([a-z0-9][a-z0-9-]*)", line)
        for t in cmds:
            ntarget += 1
            if t not in targets:
                errs.append(f"{f}:{ln}: names `make {t}`, which isn't a Makefile target")
report(f"6 repo references ({npath} paths, {ntarget} make targets in {len(current)} current docs)", errs)

for k, v in results.items():
    print(("FAIL " if v else "PASS ") + k)
    for e in v:
        print("     - " + e)
for u in sorted(ext):
    print("URL " + u)
sys.exit(1 if any(results.values()) else 0)
PY
)"
py_rc=$?
printf '%s\n' "$py_out" | grep -v '^URL '
[ $py_rc -ne 0 ] && status=1

# ---- 3 external links
if [ "${OFFLINE:-0}" = "1" ]; then
  echo "SKIP 3 links: external (OFFLINE=1). Not a pass."
  status=1
else
  # A definite answer (e.g. 404) fails at once. Rate limits, server errors and no response (429, 5xx, 000) are
  # retried LINK_RETRIES times (D-106). When the server sends Retry-After (seconds or an HTTP date), the wait is that
  # plus LINK_RETRY_BUFFER seconds; otherwise 5/10/20 s backoff. Each wait is capped at LINK_RETRY_MAX_WAIT. The wait
  # applies to the whole host, so the next link to a rate-limited host waits too instead of spending its own retries
  # (D-110).
  LINK_RETRIES="${LINK_RETRIES:-3}"; LINK_RETRY_BUFFER="${LINK_RETRY_BUFFER:-3}"; LINK_RETRY_MAX_WAIT="${LINK_RETRY_MAX_WAIT:-120}"
  hdr="$(mktemp)"
  probe() { curl -s -o /dev/null -L --max-time 25 -A 'verify-docs' -D "$hdr" -w '%{http_code}' "$@" || true; }
  # retry_after_s: the last Retry-After in the response headers as seconds from now (empty if none or unparsable).
  retry_after_s() {
    local v t; v="$(tr -d '\r' <"$hdr" | sed -n 's/^[Rr]etry-[Aa]fter: *//p' | tail -1)"
    case "$v" in
      '') return 0 ;;
      *[!0-9]*) t="$(date -u -d "$v" +%s 2>/dev/null)" || return 0; t=$((t - $(date -u +%s))); [ "$t" -lt 0 ] && t=0; echo "$t" ;;
      *) echo "$v" ;;
    esac
  }
  host_of() { sed -E 's#^[a-z]+://([^/:]+).*#\1#' <<<"$1"; }
  host_waits=""   # lines "<host> <epoch>": don't probe <host> again before <epoch>
  wait_for_host() {
    local until now; until="$(awk -v h="$1" '$1 == h {print $2}' <<<"$host_waits" | tail -1)"; now="$(date +%s)"
    [ -n "$until" ] && [ "$until" -gt "$now" ] && sleep $((until - now))
    return 0
  }
  bad=0; n=0; retried=0
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    n=$((n+1)); attempt=0; host="$(host_of "$url")"
    while :; do
      wait_for_host "$host"
      code="$(probe -I "$url")"
      case "$code" in 2*|3*) ;; *) code="$(probe "$url")";; esac
      case "$code" in 429|5??|000) ;; *) break;; esac
      # Record the host's wait even when this link is out of retries, so the next link to the host honors it.
      ra="$(retry_after_s)"
      if [ -n "$ra" ]; then delay=$((ra + LINK_RETRY_BUFFER)); else delay=$((5 << attempt)); fi
      if [ "$delay" -gt "$LINK_RETRY_MAX_WAIT" ]; then
        [ -n "$ra" ] && echo "     . $host asked to wait ${ra} s; waiting the ${LINK_RETRY_MAX_WAIT} s cap"
        delay="$LINK_RETRY_MAX_WAIT"
      fi
      host_waits="$host_waits"$'\n'"$host $(( $(date +%s) + delay ))"
      [ "$attempt" -ge "$LINK_RETRIES" ] && break
      attempt=$((attempt+1))
    done
    [ "$attempt" -gt 0 ] && retried=$((retried+1))
    case "$code" in
      2*|3*) [ "$attempt" -gt 0 ] && echo "     ~ $url -> HTTP $code after $attempt retries" ;;
      *) echo "     - $url -> HTTP $code (after $attempt retries)"; bad=$((bad+1)) ;;
    esac
  done < <(printf '%s\n' "$py_out" | sed -n 's/^URL //p')
  rm -f "$hdr"
  if [ $bad -eq 0 ]; then echo "PASS 3 links: external ($n URLs, $retried retried)"; else echo "FAIL 3 links: external ($bad of $n failed)"; status=1; fi
fi

# ---- 4 mermaid
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
"$PY" - "$tmp" <<'PY'
import glob, re, sys, os
out = sys.argv[1]
i = 0
for p in sorted(set(glob.glob("*.md") + glob.glob("docs/**/*.md", recursive=True))):
    for block in re.findall(r"```mermaid\n(.*?)```", open(p, encoding="utf-8").read(), re.S):
        i += 1
        name = re.sub(r"[^A-Za-z0-9]", "_", p) + f"_{i}.mmd"
        open(os.path.join(out, name), "w", encoding="utf-8").write(block)
PY
blocks=("$tmp"/*.mmd)
if [ ! -e "${blocks[0]}" ]; then
  echo "PASS 4 mermaid (no blocks)"
elif ! command -v npx >/dev/null 2>&1; then
  echo "UNVERIFIED 4 mermaid: npx not found (${#blocks[@]} blocks not rendered)"; status=1
else
  merr=0; unverified=0
  for b in "${blocks[@]}"; do
    if ! log="$(npx -y "$MERMAID_CLI" -q -i "$b" -o "${b%.mmd}.svg" 2>&1)"; then
      if printf '%s' "$log" | grep -qiE 'parse error|syntax error|lexical error|Expecting'; then
        echo "     - $(basename "$b"): $(printf '%s' "$log" | grep -iE 'error' | head -2 | tr '\n' ' ')"; merr=$((merr+1))
      else
        printf '     - %s: CLI could not run\n%s\n' "$(basename "$b")" "$log"
        unverified=$((unverified+1))
      fi
    fi
  done
  if [ $merr -gt 0 ]; then echo "FAIL 4 mermaid ($merr of ${#blocks[@]} blocks invalid)"; status=1
  elif [ $unverified -gt 0 ]; then echo "UNVERIFIED 4 mermaid ($unverified of ${#blocks[@]} blocks not rendered)"; status=1
  else echo "PASS 4 mermaid (${#blocks[@]} blocks rendered with $MERMAID_CLI)"; fi
fi

echo
if [ $status -eq 0 ]; then echo "verify-docs: ALL CHECKS PASS"; else echo "verify-docs: FAILED"; fi
exit $status
