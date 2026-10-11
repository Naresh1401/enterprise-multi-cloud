terraform {
  required_version = ">= 1.6.0"

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

locals {
  labels = merge(var.labels, {
    environment = var.environment
    managed-by  = "opentofu"
  })
}

resource "google_artifact_registry_repository" "app_repo" {
  location      = var.region
  repository_id = var.repository_id
  description   = "Container images for ${var.service_name}"
  format        = "DOCKER"
  labels        = local.labels
}

resource "google_cloud_run_v2_service" "app" {
  name                = var.service_name
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = var.deletion_protection
  labels              = local.labels

  template {
    # Empty means the project's default compute service account
    service_account = var.runtime_service_account != "" ? var.runtime_service_account : null

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    containers {
      name  = "multi-cloud-app"
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.app_repo.repository_id}/${var.image_name}:${var.image_tag}"

      ports {
        container_port = 8000
      }

      env {
        name  = "APP_ENV"
        value = var.environment
      }

      env {
        name  = "APP_VERSION"
        value = var.image_tag
      }

      resources {
        limits = {
          cpu    = "1000m"
          memory = "512Mi"
        }
      }

      startup_probe {
        period_seconds    = 3
        timeout_seconds   = 2
        failure_threshold = 10

        http_get {
          path = "/health"
        }
      }

      liveness_probe {
        period_seconds  = 30
        timeout_seconds = 3

        http_get {
          path = "/health"
        }
      }
    }
  }
}

# The service is a public demo endpoint; remove this binding to require
# authenticated callers.
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
