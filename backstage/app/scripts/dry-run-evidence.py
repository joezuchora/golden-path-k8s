#!/usr/bin/env python3
"""Dry-run the database request template against a running local Backstage and record the results (D-101).

Signs in as the local guest, posts the template to POST /api/scaffolder/v2/dry-run (the Template Editor's endpoint)
for both offerings, a cross-team request and an override attempt, and writes the returned workspace files and
responses under OUT_DIR/<profile>/. Usage: python scripts/dry-run-evidence.py OUT_DIR PROFILE_LABEL
"""
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.request

BASE = os.environ.get("BACKSTAGE_BACKEND", "http://localhost:7007")
HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATE = os.path.join(HERE, "..", "catalog", "request-database.yaml")

CASES = [
    ("allow-azure-horizondb", {"service": "component:default/hello", "environment": "dev", "name": "primary-db", "offering": "azure-horizondb"}),
    ("allow-cloudnative-pg", {"service": "component:default/hello", "environment": "dev", "name": "primary-db", "offering": "cloudnative-pg"}),
    ("deny-cross-team", {"service": "component:default/inventory", "environment": "dev", "name": "primary-db", "offering": "azure-horizondb"}),
    ("deny-override", {"service": "component:default/hello", "environment": "dev", "name": "primary-db", "offering": "azure-horizondb", "deployRepo": "team-b/deploy", "subscriptionId": "22222222-2222-2222-2222-222222222222"}),
]


def guest_token() -> str:
    req = urllib.request.Request(f"{BASE}/api/auth/guest/refresh?env=development", headers={"X-Requested-With": "XMLHttpRequest"})
    return json.load(urllib.request.urlopen(req))["backstageIdentity"]["token"]


def load_template() -> dict:
    import yaml  # PyYAML

    with open(TEMPLATE, encoding="utf-8") as f:
        return yaml.safe_load(f)


def dry_run(token: str, template: dict, values: dict) -> dict:
    body = json.dumps({"template": template, "values": values, "secrets": {}, "directoryContents": []}).encode()
    req = urllib.request.Request(f"{BASE}/api/scaffolder/v2/dry-run", body, {"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    try:
        r = json.load(urllib.request.urlopen(req))
    except urllib.error.HTTPError as e:
        err = json.loads(e.read().decode()).get("error", {})
        return {"status": e.code, "error": {"name": err.get("name"), "message": err.get("message")}}
    files = {f["path"]: base64.b64decode(f["base64Content"]).decode() for f in r.get("directoryContents", [])}
    logs = [re.sub(r"\[[0-9;]*m", "", l["body"]["message"]) for l in r.get("log", []) if "Rendered" in l["body"].get("message", "")]
    return {"status": 200, "files": files, "log": logs}


def main() -> None:
    out, label = sys.argv[1], sys.argv[2]
    token, template = guest_token(), load_template()
    summary = {}
    for name, values in CASES:
        result = dry_run(token, template, values)
        summary[name] = {"values": values, **result}
        for path, contents in result.get("files", {}).items():
            dest = os.path.join(out, label, name, path)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "w", encoding="utf-8", newline="\n") as f:
                f.write(contents)
    os.makedirs(os.path.join(out, label), exist_ok=True)
    with open(os.path.join(out, label, "results.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(summary, f, indent=2)
        f.write("\n")
    for name, r in summary.items():
        print(name, r["status"], list(r.get("files", {})) or r.get("error", {}).get("name"))


if __name__ == "__main__":
    main()
