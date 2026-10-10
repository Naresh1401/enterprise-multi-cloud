variable "project_id" {
  type        = string
  description = "GCP project ID"
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
}

variable "image_name" {
  type        = string
  default     = "multi-cloud-app"
  description = "Container image name stored in Artifact Registry"
}

variable "image_tag" {
  type        = string
  default     = "latest"
  description = "Tag used for the deployed application image"
}
