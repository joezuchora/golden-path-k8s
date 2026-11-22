# One team and env on AKS (D-078, D-082): its resource group (the blast-radius boundary of ADR-0002), its Key Vault (the
# connection-secret broker across the cluster split) and the two ESO identities that reach it, mirroring kind's D-064:
#   writer  Key Vault Secrets Officer; federated to tenant-<team>-<env>/eso-vault-writer on the control-plane cluster
#   reader  Key Vault Secrets User;    federated to <team>-<env>/eso-vault-reader on every workload cluster in the env's group
#   provider Contributor on the resource group; federated to each Crossplane Azure provider's service account on the
#            control-plane cluster, used only through the namespaced ProviderConfig "tenant" in tenant-<team>-<env> (D-099)
# Crossplane composes the team's databases into the resource group as the tenant's own provider identity, so deleting
# the team's XRs must leave it empty: the provider refuses to delete a resource group that still contains resources. The
# tenant's PostgreSQL private DNS zone lives here too, so one tenant's identity can't touch another's server records.
# Tag values come from platform/tenancy/teams/<team>.yaml (ADR-0007, D-017), never from input typed for this module.

locals {
  key        = "${var.team.team}-${var.env}"
  tenant_ns  = "tenant-${local.key}"
  app_ns     = local.key
  name       = "${var.name_prefix}-${local.key}"
  kv_name    = "kv${var.environment_id}${substr(sha1(local.key), 0, 8)}" # globally unique, <= 24 chars
  issuer_aud = ["api://AzureADTokenExchange"]
  tags = merge(var.base_tags, {
    "team"                = var.team.team
    "owner"               = var.team.owner
    "cost-center"         = var.team.costCenter
    "data-classification" = var.team.dataClassification
    "env"                 = var.env
    "app"                 = "tenant"
  })
}

resource "azurerm_resource_group" "tenant" {
  name     = "rg-${local.name}"
  location = var.location
  tags     = local.tags

  lifecycle {
    precondition {
      condition     = length(var.workload_issuers) > 0
      error_message = "No workload cluster is in group '${var.workload_group}' for ${local.key}: add one to var.workload_clusters, or change workloadGroups in platform/tenancy/teams/${var.team.team}.yaml (D-079)."
    }
  }
}

resource "azurerm_key_vault" "tenant" {
  name                       = local.kv_name
  location                   = var.location
  resource_group_name        = azurerm_resource_group.tenant.name
  tenant_id                  = var.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = false # disposable environment: destroy purges it (provider features), so the name is reusable
  soft_delete_retention_days = 7
  # Reached from both clusters' egress through the public endpoint, authorized by Azure RBAC only. A private endpoint per
  # vault is a later Phase 4 item (tracked in the Decision Log, D-087).
  public_network_access_enabled = true
  tags                          = local.tags
}

resource "azurerm_user_assigned_identity" "writer" {
  name                = "id-${local.name}-eso-writer"
  location            = var.location
  resource_group_name = azurerm_resource_group.tenant.name
  tags                = local.tags
}

resource "azurerm_user_assigned_identity" "reader" {
  name                = "id-${local.name}-eso-reader"
  location            = var.location
  resource_group_name = azurerm_resource_group.tenant.name
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "writer" {
  name                      = "control-plane"
  user_assigned_identity_id = azurerm_user_assigned_identity.writer.id
  issuer                    = var.control_issuer
  subject                   = "system:serviceaccount:${local.tenant_ns}:eso-vault-writer"
  audience                  = local.issuer_aud
}

resource "azurerm_federated_identity_credential" "reader" {
  for_each                  = var.workload_issuers
  name                      = "workload-${each.key}"
  user_assigned_identity_id = azurerm_user_assigned_identity.reader.id
  issuer                    = each.value
  subject                   = "system:serviceaccount:${local.app_ns}:eso-vault-reader"
  audience                  = local.issuer_aud
}

resource "azurerm_role_assignment" "writer" {
  scope                = azurerm_key_vault.tenant.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azurerm_user_assigned_identity.writer.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "reader" {
  scope                = azurerm_key_vault.tenant.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.reader.principal_id
  principal_type       = "ServicePrincipal"
}

# Crossplane's providers act for this tenant only as this identity (D-099, ADR-0013): Contributor on this resource group
# and the subnet-join role on the shared delegated subnet, nothing wider. A provider pod's projected token is its own
# service account's, so the identity federates to each provider's service account; azurerm serializes credential writes
# per identity (F65), so for_each doesn't hit the concurrent-write conflict (F62).
resource "azurerm_user_assigned_identity" "provider" {
  name                = "id-${local.name}-crossplane"
  location            = var.location
  resource_group_name = azurerm_resource_group.tenant.name
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "provider" {
  for_each                  = toset(var.provider_service_accounts)
  name                      = each.key
  user_assigned_identity_id = azurerm_user_assigned_identity.provider.id
  issuer                    = var.control_issuer
  subject                   = "system:serviceaccount:crossplane-system:${each.key}"
  audience                  = local.issuer_aud
}

resource "azurerm_role_assignment" "provider" {
  scope                = azurerm_resource_group.tenant.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.provider.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "provider_subnet_join" {
  scope              = var.postgres_subnet_id
  role_definition_id = var.subnet_join_role_definition_id
  principal_id       = azurerm_user_assigned_identity.provider.principal_id
  principal_type     = "ServicePrincipal"
}

# The tenant's own zone for VNet-integrated servers (the name must end in .postgres.database.azure.com), linked to the
# environment's VNet so every cluster resolves it. It sits in the tenant resource group, so the provider identity's
# Contributor covers it and no other tenant's identity reaches it (D-099).
resource "azurerm_private_dns_zone" "postgres" {
  name                = "${local.key}.${var.name_prefix}.private.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.tenant.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                 = "link-${local.name}"
  private_dns_zone_id  = azurerm_private_dns_zone.postgres.id
  virtual_network_id   = var.vnet_id
  registration_enabled = false
  tags                 = local.tags
}
