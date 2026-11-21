output "id" {
  description = "Cluster resource ID (scope for Azure RBAC role assignments)."
  value       = azurerm_kubernetes_cluster.this.id
}

output "name" {
  description = "Cluster name."
  value       = azurerm_kubernetes_cluster.this.name
}

output "oidc_issuer_url" {
  description = "OIDC issuer: the issuer of every federated credential for this cluster's service accounts (ADR-0008)."
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "fqdn" {
  description = "API server FQDN."
  value       = azurerm_kubernetes_cluster.this.fqdn
}

output "server" {
  description = "API server URL for the Argo CD cluster Secret."
  value       = "https://${azurerm_kubernetes_cluster.this.fqdn}:443"
}

output "ca_certificate" {
  description = "Cluster CA (base64), for the Argo CD cluster Secret's tlsClientConfig. Not a credential."
  value       = azurerm_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate
  sensitive   = true
}

output "node_resource_group" {
  description = "AKS-managed node resource group (removed with the cluster; checked by the teardown query)."
  value       = azurerm_kubernetes_cluster.this.node_resource_group
}
