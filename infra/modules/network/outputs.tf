output "vnet_id" {
  description = "The VNet."
  value       = azurerm_virtual_network.this.id
}

output "node_subnet_ids" {
  description = "Node subnet ID per cluster key."
  value       = { for k, s in azurerm_subnet.nodes : k => s.id }
}

output "postgres_subnet_id" {
  description = "Subnet delegated to PostgreSQL Flexible Server."
  value       = azurerm_subnet.postgres.id
}

output "postgres_subnet_cidr" {
  description = "Its CIDR: the L3/L4 egress allow for apps that declare a database (D-082)."
  value       = var.postgres_subnet
}
