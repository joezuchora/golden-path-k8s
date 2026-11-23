# One VNet per environment (D-083): a node subnet per cluster and a subnet delegated to PostgreSQL Flexible Server
# (D-082). Each tenant's private DNS zone for its servers is created in the tenant module and linked here (D-099).
# Clusters share the VNet; the split topology (ADR-0001) isolates credentials, not routes.

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "nodes" {
  for_each             = var.node_subnets
  name                 = "snet-${each.key}"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [each.value]
}

resource "azurerm_subnet" "postgres" {
  name                 = "snet-postgres"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.postgres_subnet]
  delegation {
    name = "postgres-flexible"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# The delegated subnet's NSG (D-103) carries the rules Microsoft requires for VNet-integrated Flexible Server (F66):
# PostgreSQL within the subnet (high availability and other features), outbound to Storage (WAL and backups), and outbound
# to Microsoft Entra ID, without which Entra administration and token acquisition fail (F61). Rules use addresses and
# service tags only: application security groups aren't supported here (F66). Azure's default rules stay in place: a
# blanket outbound deny isn't documented as safe for the service, so it waits for evidence from a live run (D-103).
resource "azurerm_network_security_group" "postgres" {
  name                = "nsg-${var.name_prefix}-postgres"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "allow-postgres-from-vnet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5432"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = var.postgres_subnet
  }

  security_rule {
    name                       = "allow-postgres-within-subnet"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5432"
    source_address_prefix      = var.postgres_subnet
    destination_address_prefix = var.postgres_subnet
  }

  security_rule {
    name                       = "allow-storage"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = var.postgres_subnet
    destination_address_prefix = "Storage"
  }

  security_rule {
    name                       = "allow-entra-id"
    priority                   = 120
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = var.postgres_subnet
    destination_address_prefix = "AzureActiveDirectory"
  }
}

resource "azurerm_subnet_network_security_group_association" "postgres" {
  subnet_id                 = azurerm_subnet.postgres.id
  network_security_group_id = azurerm_network_security_group.postgres.id
}
