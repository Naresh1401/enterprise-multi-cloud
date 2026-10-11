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
