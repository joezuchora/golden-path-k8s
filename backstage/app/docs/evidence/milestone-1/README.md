# Milestone 1 evidence: local database request and placement

Captured on 2026-11-22 from local Backstage at commit `6351603` (branch `feat/backstage-dependency-catalog`), with
Node 24.22.3. GitHub, Azure and Kubernetes credentials were absent (`start.sh` unsets `GITHUB_*`, `GH_TOKEN`,
`AZURE_*`, `ARM_*` and points `KUBECONFIG` at a missing file), and `app-config.yaml` has no integrations. The signed-in
identity is the guest demo user `user:default/alice`, a member of `group:default/team-a`.

## Dry runs (`scripts/dry-run-evidence.py`)

The script posts the template to `POST /api/scaffolder/v2/dry-run`, the endpoint the Template Editor uses, and stores
the workspace files it returns.

| Case | Input | `sandbox` profile | `enterprise` profile |
| --- | --- | --- | --- |
| HorizonDB | `hello` / `dev` / `primary-db` / `azure-horizondb` | 200; destination `sandbox-team-a-dev` | 200; destination `team-a-dev-lz` |
| CloudNativePG | `hello` / `dev` / `primary-db` / `cloudnative-pg` | 200; destination `sandbox-shared-workloads` | 200; destination `platform-aks-dev` |
| Cross-team | Team A's user requests Team B's `inventory` | 403 `NotAllowedError`, no files | 403 `NotAllowedError`, no files |
| Override | Adds `deployRepo` and `subscriptionId` to the form values | 400 `InputError`, no files | 400 `InputError`, no files |

In each profile, both allowed cases return exactly one file, `dependency-requests/dev/hello/primary-db.yaml`. The file
is byte-identical across the two profiles (`diff -r sandbox/allow-* enterprise/allow-*` is empty). Only the
backend-resolved destination differs, and it appears in the task log, not in the file. The per-case files and
responses are in [`sandbox/`](sandbox/) and [`enterprise/`](enterprise/).

## The form (`screenshots/`)

| Screenshot | What it shows |
| --- | --- |
| `01-compare-offerings.jpg` | HorizonDB and CloudNativePG side by side. Each card shows the operating owner, availability target, a "Preview: dry run only" badge and "Illustrative estimate, not a quote". HorizonDB shows that no regional rate is available. CloudNativePG shows allocated capacity and added node spend separately. |
| `02-review-horizondb.jpg` | The Review step, with only the four logical fields |
| `05-run-azure-horizondb.jpg` | A run through the form: the exact file plus the backend-derived owner (`group:default/team-a`), repository (`team-a/deploy`) and destination |
| `04-run-cloudnative-pg.jpg` | The same request with CloudNativePG: same path, different `offering`, destination `sandbox-shared-workloads` |
| `06-denied-cross-team.jpg` | Team A's user picks `inventory`. The step fails with "You cannot request dependencies for "inventory": it is owned by group:default/team-b and you are not a member…" and renders nothing. |

The form runs were regular (non-dry-run) tasks. They write only into the task's temporary workspace, and the template
has no publish step.
