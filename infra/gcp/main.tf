terraform {
  required_version = ">= 1.5.0"

  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

resource "google_artifact_registry_repository" "app_repo" {
  location      = var.region
  repository_id = var.repository_id
  description   = "Artifact Registry for multi-cloud app"
  format        = "DOCKER"
}

resource "google_cloud_run_v2_service" "app" {
  name     = var.service_name
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    scaling {
      min_instance_count = 1
      max_instance_count = 2
    }

    containers {
      name  = "multi-cloud-app"
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${var.repository_id}/${var.image_name}:${var.image_tag}"

      ports {
        container_port = 8000
      }

      resources {
        limits = {
          cpu    = "1000m"
          memory = "512Mi"
        }
      }
    }
  }
}

resource "google_cloud_run_v2_service_iam_member" "public_access" {
  name     = google_cloud_run_v2_service.app.name
  location = google_cloud_run_v2_service.app.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}

output "service_url" {
  value       = google_cloud_run_v2_service.app.uri
  description = "Public Cloud Run service URL"
}
