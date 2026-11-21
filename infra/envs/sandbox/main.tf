# Disposable AKS environment (Phase 4, D-083): one control cluster, one or more workload clusters, and a tenant per team
# and env. Apply, bootstrap and teardown go through infra/aks/aks.sh, which enforces a timeout, an owner and a teardown
# check; never run `tofu apply` here directly for a shared subscription.

data "azurerm_client_config" "current" {}

locals {
  prefix = "gp-${var.environment_id}"

  # Platform-owned resources: team "platform" (ADR-0007). environment-id, teardown-owner and expires-on make every leftover
  # resource findable and attributable by the teardown query (D-083).
  base_tags = {
    "environment-id"   = var.environment_id
    "teardown-owner"   = var.teardown_owner
    "expires-on"       = var.expires_on
    "managed-by"       = "opentofu"
    "contract-version" = "1.0"
  }
  platform_tags = merge(local.base_tags, {
    "team"                = "platform"
    "owner"               = "platform-oncall"
    "cost-center"         = var.platform_cost_center
    "data-classification" = "internal"
    "env"                 = var.env_name
    "app"                 = "platform"
  })

  # Team definitions are the only source of team, owner, cost center and workload groups (D-017, D-079).
  team_defs = { for t in var.teams : t => yamldecode(file("${path.module}/../../../platform/tenancy/teams/${t}.yaml")) }
  tenants = merge([for t, d in local.team_defs : {
    for e in d.envs : "${t}-${e}" => {
      team  = d
      env   = e
      group = lookup(try(d.workloadGroups, {}), e, "shared")
    }
  }]...)

  # Address plan: control nodes in the first /22, workload cluster i in the next ones, PostgreSQL in a /24 near the top.
  workload_keys = sort(keys(var.workload_clusters))
  node_subnets = merge(
    { control = cidrsubnet(var.address_space, 6, 0) },
    { for i, k in local.workload_keys : k => cidrsubnet(var.address_space, 6, i + 1) }
  )
  postgres_subnet = cidrsubnet(var.address_space, 8, 250)
}

resource "azurerm_resource_group" "platform" {
  name     = "rg-${local.prefix}-platform"
  location = var.location
  tags     = local.platform_tags
}

module "network" {
  source              = "../../modules/network"
  name_prefix         = local.prefix
  location            = var.location
  resource_group_name = azurerm_resource_group.platform.name
  address_space       = var.address_space
  node_subnets        = local.node_subnets
  postgres_subnet     = local.postgres_subnet
  tags                = local.platform_tags
}

# --- Clusters (ADR-0001): the control cluster hosts the control plane only; each workload cluster hosts workloads only.
module "control" {
  source               = "../../modules/aks-cluster"
  name                 = "aks-${local.prefix}-control"
  location             = var.location
  resource_group_name  = azurerm_resource_group.platform.name
  tenant_id            = data.azurerm_client_config.current.tenant_id
  kubernetes_version   = var.kubernetes_version
  sku_tier             = var.sku_tier
  network_mode         = "managed"
  enable_acns          = false
  subnet_id            = module.network.node_subnet_ids["control"]
  vm_size              = var.vm_size
  node_count           = var.control_node_count
  authorized_ip_ranges = var.api_server_authorized_ip_ranges
  pod_cidr             = "192.168.0.0/16"
  service_cidr         = "10.0.0.0/16"
  dns_service_ip       = "10.0.0.10"
  tags                 = merge(local.platform_tags, { "app" = "control-plane" })
}

module "workload" {
  source               = "../../modules/aks-cluster"
  for_each             = var.workload_clusters
  name                 = "aks-${local.prefix}-${each.key}"
  location             = var.location
  resource_group_name  = azurerm_resource_group.platform.name
  tenant_id            = data.azurerm_client_config.current.tenant_id
  kubernetes_version   = var.kubernetes_version
  sku_tier             = var.sku_tier
  network_mode         = var.cilium_mode
  enable_acns          = var.enable_acns
  subnet_id            = module.network.node_subnet_ids[each.key]
  vm_size              = var.vm_size
  node_count           = var.workload_node_count
  authorized_ip_ranges = var.api_server_authorized_ip_ranges
  pod_cidr             = "192.168.0.0/16"
  service_cidr         = "10.0.0.0/16"
  dns_service_ip       = "10.0.0.10"
  tags                 = merge(local.platform_tags, { "app" = "workloads" })
}

# --- Tenants: one per team and env (D-078, D-082).
module "tenant" {
  source                  = "../../modules/tenant"
  for_each                = local.tenants
  team                    = each.value.team
  env                     = each.value.env
  workload_group          = each.value.group
  environment_id          = var.environment_id
  name_prefix             = local.prefix
  location                = var.location
  tenant_id               = data.azurerm_client_config.current.tenant_id
  control_issuer          = module.control.oidc_issuer_url
  workload_issuers        = { for k, c in var.workload_clusters : k => module.workload[k].oidc_issuer_url if c.group == each.value.group }
  crossplane_principal_id = azurerm_user_assigned_identity.crossplane.principal_id
  base_tags               = local.base_tags
}
