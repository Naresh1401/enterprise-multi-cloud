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
}

variable "image_name" {
  type        = string
  default     = "multi-cloud-app"
  description = "Container image name stored in ACR"
}

variable "image_tag" {
  type        = string
  default     = "latest"
  description = "Tag used for the deployed application image"
}
