provider "azurerm" {
  subscription_id = var.subscription_id
  # Disposable environment (D-083): destroy must leave nothing behind and fail loudly if it can't.
  features {
    key_vault {
      purge_soft_delete_on_destroy    = true  # a soft-deleted vault would keep its name and look like a leak
      recover_soft_deleted_key_vaults = false # never adopt a vault from an earlier run
    }
    resource_group {
      # A tenant resource group that still holds composed resources (an XR that wasn't deleted) stops the destroy, so the
      # teardown reports it instead of silently deleting what Crossplane should have.
      prevent_deletion_if_contains_resources = true
    }
  }
  # Only the providers this environment uses are registered; the cloud preflight checks them first (D-084).
  resource_provider_registrations = "none"
}
