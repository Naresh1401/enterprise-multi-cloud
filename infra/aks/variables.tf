variable "environment" {
  type        = string
  default     = "dev"
  description = "Deployment environment name, used in resource names and tags"
}

variable "resource_group_name" {
  type        = string
  description = "Resource group for the cluster and its registry; OpenTofu creates it"
}

variable "location" {
  type        = string
  default     = "eastus"
  description = "Azure region"
}

variable "cluster_name" {
  type        = string
  default     = "multi-cloud"
  description = "AKS cluster name; the environment is appended"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.cluster_name))
    error_message = "cluster_name must be up to 31 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "acr_name" {
  type        = string
  description = "Globally unique Azure Container Registry name"

  validation {
    condition     = can(regex("^[a-z0-9]{5,50}$", var.acr_name))
    error_message = "acr_name must be 5-50 lowercase letters or digits."
  }
}

variable "kubernetes_version" {
  type        = string
  default     = null
  description = "Kubernetes version, for example 1.35; null uses the AKS default"
}

variable "node_vm_size" {
  type        = string
  default     = "Standard_D2s_v5"
  description = "VM size for the system node pool"
}

variable "node_min_count" {
  type        = number
  default     = 1
  description = "Minimum nodes for the cluster autoscaler"
}

variable "node_max_count" {
  type        = number
  default     = 3
  description = "Maximum nodes for the cluster autoscaler"
}

variable "api_allowed_cidrs" {
  type        = list(string)
  default     = []
  description = "CIDR blocks allowed to reach the Kubernetes API; empty allows any address"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Extra tags for every resource"
}

variable "vnet_cidr" {
  type        = string
  default     = "10.60.0.0/16"
  description = "Address space of the cluster's virtual network (nodes and database)"
}

variable "database_sku" {
  type        = string
  default     = "B_Standard_B1ms"
  description = "PostgreSQL flexible server size; use a General Purpose SKU such as GP_Standard_D2ds_v5 for prod"
}

variable "kubernetes_namespace" {
  type        = string
  default     = "multi-cloud-app"
  description = "Namespace the deploy workflow installs the chart in"
}

variable "release_name" {
  type        = string
  default     = "multi-cloud-app"
  description = "Helm release name; the chart names its service accounts after it"
}

variable "alert_email" {
  type        = string
  default     = ""
  description = "Email address for database and cluster node alerts; empty leaves them unmonitored"
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

variable "log_analytics_workspace_name" {
  type        = string
  default     = "law-multi-cloud-aks"
  description = "Log Analytics workspace name for Container Insights and the control plane's logs"
}
