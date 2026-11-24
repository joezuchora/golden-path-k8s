# Architecture

How the platform keeps the [Developer Contract](developer-contract.md), in three views: the path a change takes from a pull
request to a running app, the network path in each cluster profile, and how a dependency is reconciled and its credential
delivered. Each component is mapped to its promise and CNCF domain in the
[README matrix](../README.md#developer-contract-matrix); each choice is in the [Decision Log](adr/README.md). Every
diagram is rendered and syntax-checked by `scripts/verify-docs.sh` (check 4).

## 1. Developer Contract flow

A developer supplies only `app` and `env`. Every failure returns to Git with what failed and the next action. Nobody needs
`cluster-admin`.

```mermaid
flowchart LR
  dev["App team"] -->|"app, env"| tmpl["Backstage template"]
  tmpl --> pr["Git pull request"]
  pr --> ci["reusable-build-sign.yaml<br/>verify base, build, Trivy, sign, attest"]
  ci --> reg[("GHCR<br/>image, signature, SBOM, provenance")]
  pr -->|"merge"| argo["Argo CD sync<br/>team AppProject"]
  argo --> adm{"Kyverno admission<br/>signer + caller + base digest"}
  reg -.->|"verify"| adm
  adm -->|"allow"| roll["Rollout<br/>golden-service chart"]
  roll --> route["HTTPRoute<br/>HTTPS URL"]
  argo --> xr["XR in tenant namespace<br/>control cluster"]
  xr --> cp["Crossplane composition"]
  cp -->|"Ready: app connects"| roll
  adm -->|"deny: what, why, fix, docs link"| fb["PR status, PolicyReport,<br/>Backstage, idp-diagnose"]
  roll -->|"unhealthy"| fb
  cp -->|"stalled: XR conditions"| fb
  fb -->|"fix through Git"| pr
```

## 2. Network traffic path: `managed` vs. `byo` vs. kind

Apps depend only on `HTTPRoute` and `CiliumNetworkPolicy`. The mode changes the `GatewayClass` and the dataplane, not the
app's manifests (D-005, D-027).

```mermaid
flowchart LR
  client["Client"]
  subgraph managed["cilium_mode = managed (AKS default)"]
    afd1["Azure Front Door Premium + WAF<br/>opt-in"] --> eg["Envoy Gateway"]
    eg --> pod1["App pod"]
    pol1["Azure CNI Powered by Cilium<br/>L3/L4 default-deny<br/>L7/FQDN only with ACNS"] -.->|"enforces"| pod1
  end
  subgraph byo["cilium_mode = byo (AKS)"]
    afd2["Azure Front Door Premium + WAF<br/>opt-in"] --> cg2["Cilium Gateway"]
    cg2 --> pod2["App pod"]
    pol2["OSS Cilium, kube-proxy replacement<br/>L3/L4 default-deny, L7/FQDN, Hubble"] -.->|"enforces"| pod2
  end
  subgraph kind["kind (local, every PR)"]
    cg3["Cilium Gateway"] --> pod3["App pod"]
    pol3["OSS Cilium, same values as byo<br/>no Front Door"] -.->|"enforces"| pod3
  end
  client --> afd1
  client -->|"WAF disabled"| eg
  client --> afd2
  client -->|"WAF disabled"| cg2
  client --> cg3
```

With the WAF enabled, Front Door reaches the gateway's internal load balancer through a Private Link origin, and a
direct request to the origin is refused ([ADR-0004](adr/0004-edge-security-and-waf.md)).

## 3. Crossplane external-resource reconciliation, including the ESO secret path

```mermaid
flowchart TB
  subgraph control["Control cluster (kind: the same cluster)"]
    xr["PostgreSQLInstance XR<br/>namespace tenant-{team}-{env}"] --> comp{"Composition<br/>selected by label"}
    comp -->|"provider: azure"| mrs["Namespaced MRs<br/>ResourceGroup, FlexibleServer, Vault"]
    comp -->|"provider: local"| cnpg["CloudNativePG cluster"]
    comp --> csec["Composed connection Secret"]
    csec --> push["ESO PushSecret"]
    idxr["AppIdentity XR"] --> uami["UAMI, federated credential,<br/>role assignment"]
    mrs -->|"observe, diff, correct drift"| mrs
  end
  mrs --> azure[("Azure<br/>per-tenant resource group")]
  uami --> azure
  push --> kv[("Key Vault<br/>kind: Kubernetes SecretStore")]
  subgraph workload["Workload cluster: namespace {team}-{env}"]
    es["ExternalSecret"] --> wsec["Secret"]
    wsec --> app["App pod<br/>golden-service"]
    sa["ServiceAccount<br/>federated to the UAMI"] --> app
    rel["Reloader"] -.->|"restart on rotation"| app
  end
  kv --> es
  app -->|"Entra token on AKS<br/>brokered password on kind"| db[("PostgreSQL")]
  azure --- db
  cnpg --- db
```

Deletion runs in reverse: `deletionPolicy: Delete`, Crossplane `Usage` for ordering, and the per-tenant resource group as
the blast-radius boundary. Kind is the one place the identity promise deviates (brokered password instead of federation;
[ADR-0008](adr/0008-application-workload-identity.md)).
