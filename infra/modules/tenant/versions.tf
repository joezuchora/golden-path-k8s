terraform {
  required_version = ">= 1.6.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 5.13.0, < 6.0.0" # modules state a range; each env root pins the exact version (D-083)
    }
  }
}
