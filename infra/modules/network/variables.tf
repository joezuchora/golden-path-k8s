variable "name_prefix" {
  description = "Prefix for every name, e.g. gp-<environment_id>."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "resource_group_name" {
  description = "The platform resource group."
  type        = string
}

variable "address_space" {
  description = "The VNet's address space."
  type        = string
}

variable "node_subnets" {
  description = "Node subnet per cluster key (e.g. control, wl1) → CIDR."
  type        = map(string)
}

variable "postgres_subnet" {
  description = "CIDR of the subnet delegated to PostgreSQL Flexible Server (D-082)."
  type        = string
}

variable "tags" {
  description = "Required tags (ADR-0007) for every taggable resource."
  type        = map(string)
}
