# Pins (D-039, D-083): newest stable release at least 14 days old on 2026-11-21. azurerm v5.13.0 (2026-11-05; v5.14.0 is
# 8 days old), random v3.9.1 (2026-09-11). The HCL stays Terraform >= 1.6 compatible (D-013); CI runs OpenTofu v1.13.9.
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 5.13.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "= 3.9.1"
    }
  }
}
