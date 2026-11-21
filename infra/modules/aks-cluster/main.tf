# One AKS Standard cluster (ADR-0001, D-083). Every cluster: Entra ID + Azure RBAC only (local accounts disabled), the OIDC
# issuer and Workload Identity (ADR-0008), the patch upgrade channel the AKS blog recommends for the control cluster
# (F17), and an API server reachable only from var.authorized_ip_ranges.
#
# network_mode (ADR-0003, D-005):
#   managed  Azure CNI Overlay powered by Cilium (network_data_plane = cilium). Envoy Gateway serves the Gateway API (D-006).
#            ACNS (L7/FQDN add-on, D-021) only when enable_acns = true.
#   byo      network_plugin = none: OSS Cilium is installed by infra/aks/aks.sh with platform/components/cilium values.
# The control cluster always uses managed: it runs no apps, so cilium_mode doesn't apply to it.

locals {
  managed = var.network_mode == "managed"
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.name
  kubernetes_version  = var.kubernetes_version
  sku_tier            = var.sku_tier

  automatic_upgrade_channel = "patch"
  node_os_upgrade_channel   = "NodeImage"

  local_account_disabled            = true
  role_based_access_control_enabled = true
  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = var.tenant_id
  }

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  api_server_access_profile {
    authorized_ip_ranges = var.authorized_ip_ranges
  }

  default_node_pool {
    name                        = "system"
    vm_size                     = var.vm_size
    node_count                  = var.node_count
    vnet_subnet_id              = var.subnet_id
    os_sku                      = "AzureLinux"
    temporary_name_for_rotation = "rotate"
    upgrade_settings {
      max_surge = "10%"
    }
    tags = var.tags
  }

  identity {
    type = "SystemAssigned"
  }

  # Fixed node pools (the blog's control cluster runs a fixed node count, F17); node auto-provisioning isn't used.
  node_provisioning_profile {
    mode = "Manual"
  }

  network_profile {
    network_plugin      = local.managed ? "azure" : "none"
    network_plugin_mode = local.managed ? "overlay" : null
    network_data_plane  = local.managed ? "cilium" : null
    network_policy      = local.managed ? "cilium" : null
    pod_cidr            = local.managed ? var.pod_cidr : null # byo: Cilium cluster-pool IPAM (aks.sh) owns pod IPs
    service_cidr        = var.service_cidr
    dns_service_ip      = var.dns_service_ip
    load_balancer_sku   = "standard"

    dynamic "advanced_networking" {
      for_each = local.managed && var.enable_acns ? [1] : []
      content {
        observability_enabled = true
        security_enabled      = true
      }
    }
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = !var.enable_acns || local.managed
      error_message = "enable_acns needs network_mode = managed: ACNS is the L7/FQDN add-on for AKS-managed Cilium (D-021); byo Cilium has L7/FQDN without it."
    }
  }
}
