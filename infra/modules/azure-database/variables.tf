variable "server_name" {
  type        = string
  description = "Globally unique server name; it becomes <name>.postgres.database.azure.com"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.server_name))
    error_message = "server_name must be 3-63 lowercase letters, digits or hyphens."
  }
}

variable "environment" {
  type        = string
  description = "dev or prod; prod gets zone-redundant high availability and longer backups"
}

variable "resource_group_name" {
  type        = string
  description = "Resource group for the server and its DNS zone"
}

variable "location" {
  type        = string
  description = "Azure region"
}

variable "virtual_network_id" {
  type        = string
  description = "Virtual network the workloads connect from"
}

variable "delegated_subnet_id" {
  type        = string
  description = "Subnet delegated to Microsoft.DBforPostgreSQL/flexibleServers"
}

variable "tenant_id" {
  type        = string
  description = "Microsoft Entra tenant of the identities"
}

variable "admin_principal_id" {
  type        = string
  description = "Object ID of the managed identity that administers the server (the migration job's)"
}

variable "admin_principal_name" {
  type        = string
  description = "Name of that managed identity, which is also its PostgreSQL role"
}

variable "sku_name" {
  type        = string
  default     = "B_Standard_B1ms"
  description = "Server size; use a General Purpose SKU such as GP_Standard_D2ds_v5 for prod"
}

variable "postgresql_version" {
  type        = string
  default     = "17"
  description = "PostgreSQL major version"
}

variable "storage_mb" {
  type        = number
  default     = 32768
  description = "Initial storage in MB; it grows automatically"
}

variable "database_name" {
  type        = string
  default     = "app"
  description = "Database the service uses"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags for every resource"
}

variable "action_group_id" {
  type        = string
  default     = ""
  description = "Azure Monitor action group for the CPU, storage and connection alerts; empty leaves them unmonitored"
}

variable "connection_alarm_threshold" {
  type        = number
  default     = 80
  description = "Active connections sustained for 15 minutes that triggers the connections alert"
}
