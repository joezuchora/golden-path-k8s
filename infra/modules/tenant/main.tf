# One team and env on AKS (D-078, D-082): its resource group (the blast-radius boundary of ADR-0002), its Key Vault (the
# connection-secret broker across the cluster split) and the two ESO identities that reach it, mirroring kind's D-064:
#   writer  Key Vault Secrets Officer; federated to tenant-<team>-<env>/eso-vault-writer on the control-plane cluster
#   reader  Key Vault Secrets User;    federated to <team>-<env>/eso-vault-reader on every workload cluster in the env's group
# Crossplane composes the team's databases into the resource group (Contributor on it, nothing wider), so deleting the
# team's XRs must leave it empty: the provider refuses to delete a resource group that still contains resources.
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

# Crossplane composes databases (and, with AppIdentity, app identities) into this resource group only (D-082).
resource "azurerm_role_assignment" "crossplane" {
  scope                = azurerm_resource_group.tenant.id
  role_definition_name = "Contributor"
  principal_id         = var.crossplane_principal_id
  principal_type       = "ServicePrincipal"
}
