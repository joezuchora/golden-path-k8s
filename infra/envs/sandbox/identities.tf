# Platform identities (D-081, D-085). All are user-assigned managed identities federated to a named service account on the
# control-plane cluster: no client secret, no kubeconfig, no stored cloud credential anywhere. The split-topology check
# (ADR-0001) asserts that none of them, and no Crossplane object, exists on a workload cluster.

# Crossplane (control plane only): composes team resources into tenant resource groups (Contributor there, granted per
# tenant in modules/tenant), and joins VNet-integrated servers to the delegated subnet and the private DNS zone (D-082).
resource "azurerm_user_assigned_identity" "crossplane" {
  name                = "id-${local.prefix}-crossplane"
  location            = var.location
  resource_group_name = azurerm_resource_group.platform.name
  tags                = local.platform_tags
}

resource "azurerm_federated_identity_credential" "crossplane" {
  for_each                  = toset(var.crossplane_provider_service_accounts)
  name                      = each.key
  user_assigned_identity_id = azurerm_user_assigned_identity.crossplane.id
  issuer                    = module.control.oidc_issuer_url
  subject                   = "system:serviceaccount:crossplane-system:${each.key}"
  audience                  = ["api://AzureADTokenExchange"]
}

resource "azurerm_role_assignment" "crossplane_subnet" {
  scope                = module.network.postgres_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.crossplane.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "crossplane_dns" {
  scope                = module.network.postgres_private_dns_zone_id
  role_definition_name = "Private DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.crossplane.principal_id
  principal_type       = "ServicePrincipal"
}

# Argo CD (the hub on the control cluster, ADR-0001): deploys to every workload cluster through Azure RBAC, using
# argocd-k8s-auth with workload identity in each cluster Secret (F55). The controller and the server both talk to clusters.
resource "azurerm_user_assigned_identity" "argocd" {
  name                = "id-${local.prefix}-argocd"
  location            = var.location
  resource_group_name = azurerm_resource_group.platform.name
  tags                = local.platform_tags
}

resource "azurerm_federated_identity_credential" "argocd" {
  for_each                  = toset(["argocd-application-controller", "argocd-server"])
  name                      = each.key
  user_assigned_identity_id = azurerm_user_assigned_identity.argocd.id
  issuer                    = module.control.oidc_issuer_url
  subject                   = "system:serviceaccount:argocd:${each.key}"
  audience                  = ["api://AzureADTokenExchange"]
}

resource "azurerm_role_assignment" "argocd_workload" {
  for_each             = var.workload_clusters
  scope                = module.workload[each.key].id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = azurerm_user_assigned_identity.argocd.principal_id
  principal_type       = "ServicePrincipal"
}

# The operator who runs infra/aks/aks.sh bootstraps both clusters (installs Argo CD and the cluster Secrets). This is the
# platform team's break-glass path, not a developer path: developers get namespaced RBAC only (D-025).
resource "azurerm_role_assignment" "operator" {
  for_each             = merge({ control = module.control.id }, { for k, m in module.workload : k => m.id })
  scope                = each.value
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}
