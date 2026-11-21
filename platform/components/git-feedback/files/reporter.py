"""git-feedback reporter (D-075): turn Argo CD render failures into a failed commit status on the team's deploy repo.

Argo CD notifications report sync operations (D-043, D-067). A values file that doesn't render (for example
`replicas: 21`, rejected by golden-service's schema) never starts a sync: Argo CD records a ComparisonError and no
revision, so no notification can name the commit. This loop finds team applications in that state, asks the Git host
for the head of the branch Argo CD renders (the revision it attempted), and posts a failure status there with the render
error, under the same context Argo CD notifications use. Each application and revision is reported once. Gitea and
GitHub share these API calls (`GET /repos/{o}/{r}/branches/{b}`, `GET .../commits/{sha}/statuses`,
`POST /repos/{o}/{r}/statuses/{sha}`), so only GIT_API differs.

Standard library only. Reads Applications in its own namespace; writes nothing to the cluster.
"""
import json
import os
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

NAMESPACE = os.environ.get("NAMESPACE", "argocd")
GIT_API = os.environ["GIT_API"].rstrip("/")
GIT_TOKEN = open(os.environ.get("GIT_TOKEN_FILE", "/var/run/git/git-token")).read().strip()
DOCS = os.environ.get("DOCS_URL", "")
INTERVAL = int(os.environ.get("INTERVAL_SECONDS", "20"))
SA = "/var/run/secrets/kubernetes.io/serviceaccount"
K8S = "https://kubernetes.default.svc"
CTX = ssl.create_default_context(cafile=f"{SA}/ca.crt")


def k8s(path):
    token = open(f"{SA}/token").read().strip()
    req = urllib.request.Request(K8S + path, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, context=CTX, timeout=10) as r:
        return json.load(r)


def git(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(GIT_API + path, data=data, method=method, headers={
        "Authorization": f"token {GIT_TOKEN}", "Content-Type": "application/json", "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)


def repo_of(url):
    path = urllib.parse.urlparse(url).path.strip("/")
    return path[:-4] if path.endswith(".git") else path


def target(app):
    """(deploy repo owner/name, path in it, branch) for a team application, or None."""
    spec = app["spec"]
    if spec.get("sources"):  # an app: golden-service chart + values from the deploy repo
        values_src = spec["sources"][1]
        files = (spec["sources"][0].get("helm") or {}).get("valueFiles", [])
        path = next((f[len("$values/"):] for f in files if f.startswith("$values/")), None)
        return (repo_of(values_src["repoURL"]), path, values_src.get("targetRevision", "main")) if path else None
    src = spec.get("source") or {}  # an XR application: one directory of the deploy repo
    return (repo_of(src["repoURL"]), src.get("path", ""), src.get("targetRevision", "main")) if src.get("repoURL") else None


REPORTED = set()  # (application, revision) pairs already reported by this process


def head(repo, branch):
    commit = git("GET", f"/repos/{repo}/branches/{urllib.parse.quote(branch)}")["commit"]
    return commit.get("id") or commit.get("sha")  # Gitea: id; GitHub: sha


def report(app, message):
    name = app["metadata"]["name"]
    t = target(app)
    if not t:
        return
    repo, path, branch = t
    sha = head(repo, branch)
    if (name, sha) in REPORTED:
        return
    context = f"platform/argocd/{name}"
    detail = message.replace("\n", " ")
    # Lead with the chart's own error (for a schema failure: "- at '/replicas': maximum: got 21, want 20"), not the
    # helm command line Argo CD wraps it in.
    for marker in ("- at '", "Error: execution error", "Error: "):
        if marker in detail:
            detail = detail[detail.index(marker):]
            break
    description = (f"Render failed: {path} in {repo} doesn't produce valid manifests: {detail[:600]} "
                   f"Fix: correct the values in your PR (golden-service values.schema.json lists every allowed value). "
                   f"Docs: {DOCS}")[:1000]
    existing = git("GET", f"/repos/{repo}/commits/{sha}/statuses")
    if not any(s.get("context") == context and (s.get("description") or "").startswith("Render failed:") for s in existing):
        git("POST", f"/repos/{repo}/statuses/{sha}", {"state": "failure", "context": context, "description": description})
    REPORTED.add((name, sha))
    print(f"reported render failure of {name} on {repo}@{sha[:12]} ({path})", flush=True)


def main():
    print(f"git-feedback reporter: watching {NAMESPACE} every {INTERVAL}s, Git API {GIT_API}", flush=True)
    while True:
        try:
            apps = k8s(f"/apis/argoproj.io/v1alpha1/namespaces/{NAMESPACE}/applications"
                       "?labelSelector=platform.example.org%2Fgit-feedback%3Dtrue")["items"]
            for app in apps:
                for c in (app.get("status") or {}).get("conditions") or []:
                    if c.get("type") == "ComparisonError":
                        try:
                            report(app, c.get("message", ""))
                        except (urllib.error.URLError, KeyError, ValueError) as e:
                            print(f"could not report {app['metadata']['name']}: {e}", flush=True)
                        break
        except (urllib.error.URLError, KeyError, ValueError) as e:
            print(f"loop error: {e}", flush=True)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
