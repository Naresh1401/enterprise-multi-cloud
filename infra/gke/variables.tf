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
  description = "Deployment environment name, used in resource names and labels"
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "GCP region; the Autopilot cluster is regional"
}

variable "cluster_name" {
  type        = string
  default     = "multi-cloud"
  description = "GKE cluster name; the environment is appended"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.cluster_name))
    error_message = "cluster_name must be up to 31 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "repository_id" {
  type        = string
  default     = "multi-cloud-app-gke"
  description = "Artifact Registry repository (separate from the Cloud Run one so both can share a project)"
}

variable "subnet_cidr" {
  type        = string
  default     = "10.40.0.0/20"
  description = "Primary range of the cluster subnet (nodes)"
}

variable "pods_cidr" {
  type        = string
  default     = "10.44.0.0/14"
  description = "Secondary range for pods"
}

variable "services_cidr" {
  type        = string
  default     = "10.48.0.0/20"
  description = "Secondary range for services"
}

variable "api_allowed_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDR blocks allowed to reach the public Kubernetes API endpoint"
}

variable "deletion_protection" {
  type        = bool
  default     = true
  description = "Block OpenTofu from deleting the cluster"
}

variable "labels" {
  type        = map(string)
  default     = {}
  description = "Extra labels applied to every resource"
}

variable "database_tier" {
  type        = string
  default     = "db-custom-1-3840"
  description = "Cloud SQL machine type; db-custom-1-3840 allows 100 connections"
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
  description = "Email address for database, node CPU and container restart alerts; empty leaves them unmonitored"
}

variable "enable_customer_managed_key" {
  type        = bool
  default     = false
  description = "Encrypt the image repository and database with a customer-managed Cloud KMS key instead of Google's own. Set before the first apply: enabling it later replaces the repository and the instance"
}
