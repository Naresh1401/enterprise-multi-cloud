variable "name" {
  type        = string
  description = "Name of the instance and the prefix of its service accounts, for example multi-cloud-dev"
}

variable "environment" {
  type        = string
  description = "dev or prod; prod gets a regional (high availability) instance and longer backups"
}

variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "region" {
  type        = string
  description = "Region of the instance"
}

variable "network_id" {
  type        = string
  description = "VPC the instance gets its private IP in"
}

variable "tier" {
  type        = string
  default     = "db-custom-1-3840"
  description = "Machine type; db-custom-1-3840 is 1 vCPU and 3.75 GB with 100 connections"
}

variable "database_version" {
  type        = string
  default     = "POSTGRES_17"
  description = "PostgreSQL version"
}

variable "database_name" {
  type        = string
  default     = "app"
  description = "Database the service uses"
}

variable "deletion_protection" {
  type        = bool
  default     = true
  description = "Block deleting the instance, in OpenTofu and in Cloud SQL itself"
}

variable "labels" {
  type        = map(string)
  default     = {}
  description = "Labels for the instance"
}
