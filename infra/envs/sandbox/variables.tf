# Every value that decides cost, place or ownership is required: no defaults for subscription, region, owner or expiry
# (D-083). infra/aks/aks.sh refuses to apply without them, and the cloud preflight checks them first (D-084).

variable "subscription_id" {
  description = "Azure subscription for the whole environment."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.subscription_id))
    error_message = "subscription_id must be a subscription GUID."
  }
}

variable "location" {
  description = "Azure region, e.g. eastus2. Checked by the preflight for AKS version, VM quota and PostgreSQL availability."
  type        = string
}

variable "environment_id" {
  description = "Short id that names and tags every resource (3-8 lowercase letters/digits, starting with a letter)."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,7}$", var.environment_id))
    error_message = "environment_id must be 3-8 lowercase letters or digits, starting with a letter."
  }
}

variable "env_name" {
  description = "The platform environment's name (the env tag on platform resources)."
  type        = string
  default     = "sandbox"
}

variable "teardown_owner" {
  description = "Who tears this environment down if a run is interrupted (an email or alias). Tagged on every resource."
  type        = string
  validation {
    condition     = length(trimspace(var.teardown_owner)) > 0
    error_message = "teardown_owner is required (exit criterion: every AKS job has an owner)."
  }
}

variable "expires_on" {
  description = "Date (YYYY-MM-DD) after which any remaining resource is a leak. Tagged on every resource."
  type        = string
  validation {
    condition     = can(regex("^\\d{4}-\\d{2}-\\d{2}$", var.expires_on))
    error_message = "expires_on must be YYYY-MM-DD."
  }
}

variable "platform_cost_center" {
  description = "Cost center for platform-owned resources (team: platform)."
  type        = string
}

variable "api_server_authorized_ip_ranges" {
  description = "CIDRs that may reach the clusters' API servers (the operator's egress IP). Never empty."
  type        = list(string)
  validation {
    condition     = length(var.api_server_authorized_ip_ranges) > 0 && alltrue([for c in var.api_server_authorized_ip_ranges : can(cidrhost(c, 0))])
    error_message = "api_server_authorized_ip_ranges needs at least one valid CIDR; an open API server isn't an option."
  }
}

variable "cilium_mode" {
  description = "Workload clusters' networking (D-005): managed (default) or byo."
  type        = string
  default     = "managed"
  validation {
    condition     = contains(["managed", "byo"], var.cilium_mode)
    error_message = "cilium_mode must be managed or byo."
  }
}

variable "enable_acns" {
  description = "ACNS on managed workload clusters: the optional L7/FQDN profile (D-021). Opt-in, with its own cost."
  type        = bool
  default     = false
}

variable "enable_edge_waf" {
  description = "Azure Front Door Premium + WAF (ADR-0004, D-007). Opt-in; the module isn't built yet."
  type        = bool
  default     = false
  validation {
    condition     = !var.enable_edge_waf
    error_message = "The edge-waf module isn't built yet (a later Phase 4 slice, tracked as D-087); leave enable_edge_waf = false."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes minor for every cluster (= the kind node and kubectl minor). AKS GA in Oct 2026 (F52)."
  type        = string
  default     = "1.37"
}

variable "sku_tier" {
  description = "AKS tier for every cluster (Free: no uptime SLA; fine for a disposable environment)."
  type        = string
  default     = "Free"
}

variable "vm_size" {
  description = "Node VM size for every cluster."
  type        = string
  default     = "Standard_D4as_v5"
}

variable "control_node_count" {
  description = "Nodes in the control cluster."
  type        = number
  default     = 2
}

variable "workload_node_count" {
  description = "Nodes in each workload cluster."
  type        = number
  default     = 2
}

variable "workload_clusters" {
  description = "Workload clusters (key → its workload group, D-079). Start with one; add a second spoke only after the first passes."
  type        = map(object({ group = string }))
  default     = { wl1 = { group = "shared" } }
  validation {
    condition     = length(var.workload_clusters) > 0 && alltrue([for k, v in var.workload_clusters : can(regex("^[a-z][a-z0-9]{1,7}$", k)) && can(regex("^[a-z][a-z0-9-]{0,30}$", v.group))])
    error_message = "workload_clusters needs at least one entry; keys are 2-8 lowercase letters/digits, groups are DNS labels."
  }
}

variable "teams" {
  description = "Teams (platform/tenancy/teams/<team>.yaml) that get a tenant (resource group, Key Vault, ESO identities) per env."
  type        = list(string)
  default     = ["team-a"]
}

variable "crossplane_provider_service_accounts" {
  description = "Service accounts of the Crossplane providers that need Azure access (crossplane-config DeploymentRuntimeConfigs); each tenant's provider identity federates to every one (D-099)."
  type        = list(string)
  default     = ["provider-family-azure", "provider-azure-dbforpostgresql"]
}

variable "address_space" {
  description = "The environment VNet."
  type        = string
  default     = "10.40.0.0/16"
}
