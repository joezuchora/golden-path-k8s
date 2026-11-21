output "tenant_namespace" {
  description = "The control-plane tenant namespace."
  value       = local.tenant_ns
}

output "resource_group" {
  description = "The tenant resource group (compositions put the team's resources here)."
  value       = azurerm_resource_group.tenant.name
}

output "key_vault_url" {
  description = "The team-env Key Vault."
  value       = azurerm_key_vault.tenant.vault_uri
}

output "writer_client_id" {
  description = "Client ID of the ESO writer identity."
  value       = azurerm_user_assigned_identity.writer.client_id
}

output "reader_client_id" {
  description = "Client ID of the ESO reader identity."
  value       = azurerm_user_assigned_identity.reader.client_id
}

output "principal_ids" {
  description = "Principal IDs created here, for the teardown check (no role assignment may outlive its identity)."
  value       = [azurerm_user_assigned_identity.writer.principal_id, azurerm_user_assigned_identity.reader.principal_id]
}
