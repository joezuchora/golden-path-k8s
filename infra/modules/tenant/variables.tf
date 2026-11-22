variable "team" {
  description = "The team definition, decoded from platform/tenancy/teams/<team>.yaml."
  type = object({
    team               = string
    owner              = string
    costCenter         = string
    dataClassification = string
  })
}

variable "env" {
  description = "The env (one of the team definition's envs)."
  type        = string
}

variable "workload_group" {
  description = "The env's workload group (D-079)."
  type        = string
}

variable "environment_id" {
  description = "Short environment id (also part of the Key Vault name)."
  type        = string
}

variable "name_prefix" {
  description = "gp-<environment_id>."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "tenant_id" {
  description = "Microsoft Entra tenant."
  type        = string
}

variable "control_issuer" {
  description = "OIDC issuer of the control-plane cluster."
  type        = string
}

variable "workload_issuers" {
  description = "OIDC issuer per workload cluster in the env's group (cluster key → issuer)."
  type        = map(string)
}

variable "provider_service_accounts" {
  description = "Service accounts of the Crossplane Azure providers on the control-plane cluster (crossplane-config DeploymentRuntimeConfigs)."
  type        = list(string)
}

variable "vnet_id" {
  description = "The environment's VNet, linked to the tenant's PostgreSQL private DNS zone."
  type        = string
}

variable "postgres_subnet_id" {
  description = "The subnet delegated to PostgreSQL Flexible Server (shared by the environment's tenants)."
  type        = string
}

variable "subnet_join_role_definition_id" {
  description = "Resource ID of the custom role that only allows joining the delegated subnet (D-099)."
  type        = string
}

variable "base_tags" {
  description = "Environment tags (environment-id, teardown-owner, expires-on, managed-by, contract-version)."
  type        = map(string)
}
