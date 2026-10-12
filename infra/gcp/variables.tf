variable "project_id" {
  type        = string
  description = "GCP project ID"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project ID (6-30 lowercase letters, digits or hyphens)."
  }
}

variable "environment" {
  type        = string
  default     = "dev"
  description = "Deployment environment name, used for APP_ENV and resource labels"
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "GCP region"
}

variable "repository_id" {
  type        = string
  default     = "multi-cloud-app"
  description = "Artifact Registry repository name"
}

variable "service_name" {
  type        = string
  default     = "multi-cloud-app"
  description = "Cloud Run service name"

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{0,47}[a-z0-9])?$", var.service_name))
    error_message = "service_name must be up to 49 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "image_name" {
  type        = string
  default     = "multi-cloud-app"
  description = "Container image name stored in Artifact Registry"
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

variable "migration_token" {
  type        = string
  default     = ""
  description = "A new value runs the migration job during the apply (the deploy workflow passes its run ID); empty runs nothing"

  validation {
    condition     = can(regex("^[a-z0-9-]*$", var.migration_token))
    error_message = "migration_token may only hold lowercase letters, digits and hyphens."
  }
}

variable "subnet_cidr" {
  type        = string
  default     = "10.50.0.0/24"
  description = "Subnet the service and the migration job send private traffic from"
}

variable "database_tier" {
  type        = string
  default     = "db-custom-1-3840"
  description = "Cloud SQL machine type; db-custom-1-3840 allows 100 connections"
}

variable "min_instances" {
  type        = number
  default     = 1
  description = "Minimum number of Cloud Run instances"
}

variable "max_instances" {
  type        = number
  default     = 2
  description = "Maximum number of Cloud Run instances"
}

variable "deletion_protection" {
  type        = bool
  default     = true
  description = "Block deleting the Cloud Run service, the migration job and the Cloud SQL instance"
}

variable "labels" {
  type        = map(string)
  default     = {}
  description = "Extra labels applied to every resource"
}

variable "alert_email" {
  type        = string
  default     = ""
  description = "Email address for the database, error rate and latency alerts; empty leaves them unmonitored"
}
