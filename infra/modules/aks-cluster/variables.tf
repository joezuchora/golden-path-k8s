variable "name" {
  description = "Cluster name; also its DNS prefix."
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

variable "tenant_id" {
  description = "Microsoft Entra tenant for Azure RBAC."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes minor (AKS picks the newest patch; the patch channel keeps it current)."
  type        = string
}

variable "sku_tier" {
  description = "AKS tier: Free for a disposable environment, Standard for an uptime SLA."
  type        = string
  validation {
    condition     = contains(["Free", "Standard"], var.sku_tier)
    error_message = "sku_tier must be Free or Standard."
  }
}

variable "network_mode" {
  description = "managed (Azure CNI Powered by Cilium) or byo (network_plugin = none, OSS Cilium) (D-005)."
  type        = string
  validation {
    condition     = contains(["managed", "byo"], var.network_mode)
    error_message = "network_mode must be managed or byo."
  }
}

variable "enable_acns" {
  description = "Advanced Container Networking Services (the L7/FQDN add-on on managed, D-021). Opt-in; it has its own cost."
  type        = bool
}

variable "subnet_id" {
  description = "Node subnet."
  type        = string
}

variable "vm_size" {
  description = "Node VM size."
  type        = string
}

variable "node_count" {
  description = "Nodes in the system pool."
  type        = number
}

variable "authorized_ip_ranges" {
  description = "CIDRs allowed to reach the API server. Never empty: an open API server isn't an option (D-083)."
  type        = list(string)
  validation {
    condition     = length(var.authorized_ip_ranges) > 0
    error_message = "authorized_ip_ranges can't be empty."
  }
}

variable "pod_cidr" {
  description = "Pod CIDR (overlay on managed; Cilium cluster-pool on byo)."
  type        = string
}

variable "service_cidr" {
  description = "Service CIDR."
  type        = string
}

variable "dns_service_ip" {
  description = "kube-dns service IP, inside service_cidr."
  type        = string
}

variable "tags" {
  description = "Required tags (ADR-0007)."
  type        = map(string)
}
