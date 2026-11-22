# Everything infra/aks/aks.sh needs to bootstrap the clusters (D-081): cluster Secrets and their annotations, the
# EnvironmentConfig for compositions, and the teardown record. IDs, not credentials: nothing here is a secret except the
# cluster CA bundle, which is marked sensitive only to keep it out of logs.

output "environment" {
  description = "Environment identity and teardown record."
  value = {
    environment_id  = var.environment_id
    env_name        = var.env_name
    location        = var.location
    subscription_id = var.subscription_id
    tenant_id       = data.azurerm_client_config.current.tenant_id
    cilium_mode     = var.cilium_mode
    enable_acns     = var.enable_acns     # opt-in (D-021)
    enable_edge_waf = var.enable_edge_waf # opt-in (ADR-0004); refused until the module exists
    teardown_owner  = var.teardown_owner
    expires_on      = var.expires_on
    platform_rg     = azurerm_resource_group.platform.name
    node_rgs        = concat([module.control.node_resource_group], [for m in module.workload : m.node_resource_group])
    tenant_rgs      = [for t in module.tenant : t.resource_group]
    identity_principals = concat(
      [azurerm_user_assigned_identity.argocd.principal_id],
      flatten([for t in module.tenant : t.principal_ids])
    )
    # Untagged, so verify-teardown checks for it by name (D-099).
    custom_roles = [azurerm_role_definition.postgres_subnet_join.name]
  }
}

output "clusters" {
  description = "Control and workload clusters."
  value = {
    control = {
      name   = module.control.name
      server = module.control.server
      issuer = module.control.oidc_issuer_url
    }
    workloads = { for k, m in module.workload : k => {
      name   = m.name
      server = m.server
      issuer = m.oidc_issuer_url
      group  = var.workload_clusters[k].group
    } }
  }
}

output "cluster_ca" {
  description = "Cluster CA bundles (base64) for the Argo CD cluster Secrets."
  value       = merge({ control = module.control.ca_certificate }, { for k, m in module.workload : k => m.ca_certificate })
  sensitive   = true
}

output "identities" {
  description = "Client IDs of the platform identities. Crossplane has none of its own: see tenants.providerClientId (D-099)."
  value = {
    argocd = azurerm_user_assigned_identity.argocd.client_id
  }
}

output "postgres" {
  description = "VNet integration for the azure PostgreSQL composition (D-082); each tenant's DNS zone is in tenants (D-099)."
  value = {
    subnet_id   = module.network.postgres_subnet_id
    subnet_cidr = module.network.postgres_subnet_cidr
  }
}

output "tenants" {
  description = "Per team and env: resource group, Key Vault, ESO and provider identities, DNS zone (the tenancy-values annotation, D-078, D-099)."
  value = { for k, t in module.tenant : k => {
    tenant_namespace         = t.tenant_namespace
    resource_group           = t.resource_group
    keyVaultUrl              = t.key_vault_url
    writerClientId           = t.writer_client_id
    readerClientId           = t.reader_client_id
    providerClientId         = t.provider_client_id
    postgresPrivateDnsZoneId = t.postgres_private_dns_zone_id
  } }
}
