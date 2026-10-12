variable "environment" {
  type        = string
  default     = "dev"
  description = "Deployment environment name, used for APP_ENV and resource tags"
}

variable "resource_group_name" {
  type        = string
  default     = "rg-multi-cloud-demo"
  description = "Azure Resource Group name"
}

variable "location" {
  type        = string
  default     = "eastus"
  description = "Azure region"
}

variable "acr_name" {
  type        = string
  description = "Globally unique Azure Container Registry name"

  validation {
    condition     = can(regex("^[a-z0-9]{5,50}$", var.acr_name))
    error_message = "acr_name must be 5-50 lowercase letters or digits."
  }
}

variable "log_analytics_workspace_name" {
  type        = string
  default     = "law-multi-cloud-demo"
  description = "Log Analytics workspace name"
}

variable "container_app_environment_name" {
  type        = string
  default     = "cae-multi-cloud-demo"
  description = "Azure Container Apps environment name"
}

variable "container_app_name" {
  type        = string
  default     = "multi-cloud-app"
  description = "Azure Container App name"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}[a-z0-9]$", var.container_app_name))
    error_message = "container_app_name must be 2-32 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "image_name" {
  type        = string
  default     = "multi-cloud-app"
  description = "Container image name stored in ACR"
}

variable "image_tag" {
  type        = string
  default     = "latest"
  description = "Image tag to deploy; the deployment workflow passes the commit SHA"

  validation {
    condition     = length(trimspace(var.image_tag)) > 0
    error_message = "image_tag must not be empty."
  }
}

variable "min_replicas" {
  type        = number
  default     = 1
  description = "Minimum number of running replicas"
}

variable "max_replicas" {
  type        = number
  default     = 2
  description = "Maximum number of running replicas"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Extra tags applied to every resource"
}

variable "vnet_cidr" {
  type        = string
  default     = "10.70.0.0/16"
  description = "Address space of the virtual network (Container Apps environment and database)"
}

variable "database_sku" {
  type        = string
  default     = "B_Standard_B1ms"
  description = "PostgreSQL flexible server size; use a General Purpose SKU such as GP_Standard_D2ds_v5 for prod"
}

variable "alert_email" {
  type        = string
  default     = ""
  description = "Email address for database, restart and error-rate alerts; empty leaves them unmonitored"
}

variable "enable_customer_managed_key" {
  type        = bool
  default     = false
  description = "Encrypt the database with a customer-managed Key Vault key instead of Azure's own. Set before the first apply: enabling it later replaces the server"
}

variable "key_vault_name" {
  type        = string
  default     = ""
  description = "Globally unique Key Vault name (3-24 characters); required when enable_customer_managed_key is true"

  validation {
    condition     = var.key_vault_name == "" || can(regex("^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$", var.key_vault_name))
    error_message = "key_vault_name must be empty or 3-24 letters, digits or hyphens, starting with a letter."
  }
}
