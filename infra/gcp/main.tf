terraform {
  required_version = ">= 1.6.0"

  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.0"
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
  image        = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.app_repo.repository_id}/${var.image_name}:${var.image_tag}"
  migrate_name = "${var.service_name}-migrate"
  # The service and the migration job leave through the VPC for private addresses only,
  # which is how they reach the database's private IP
  vpc_egress = {
    network    = google_compute_network.this.id
    subnetwork = google_compute_subnetwork.run.id
  }
}

resource "google_compute_network" "this" {
  name                    = var.service_name
  auto_create_subnetworks = false
}

# Direct VPC egress: the service's instances and the job's tasks get addresses here
resource "google_compute_subnetwork" "run" {
  name                     = "${var.service_name}-run"
  region                   = var.region
  network                  = google_compute_network.this.id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# PostgreSQL with a private IP only. The service and the migration job each run as their own
# service account and sign in to it with IAM; no database password exists.
module "database" {
  source = "../modules/gcp-database"

  name                  = var.service_name
  environment           = var.environment
  project_id            = var.project_id
  region                = var.region
  network_id            = google_compute_network.this.id
  tier                  = var.database_tier
  deletion_protection   = var.deletion_protection
  labels                = local.labels
  notification_channels = local.notification_channels
}

resource "google_artifact_registry_repository" "app_repo" {
  location      = var.region
  repository_id = var.repository_id
  description   = "Container images for ${var.service_name}"
  format        = "DOCKER"
  labels        = local.labels
}

# The migrations, as a job. Each deployment passes a new migration_token, and OpenTofu then
# runs the job once and waits for it to succeed before it updates the service below.
resource "google_cloud_run_v2_job" "migrate" {
  name                = local.migrate_name
  location            = var.region
  deletion_protection = var.deletion_protection
  labels              = local.labels
  run_execution_token = var.migration_token != "" ? var.migration_token : null

  template {
    task_count = 1

    template {
      service_account = module.database.migration_service_account
      max_retries     = 1
      timeout         = "600s"

      vpc_access {
        egress = "PRIVATE_RANGES_ONLY"
        network_interfaces {
          network    = local.vpc_egress.network
          subnetwork = local.vpc_egress.subnetwork
        }
      }

      containers {
        image   = local.image
        command = ["python", "-m", "app.migrate"]

        dynamic "env" {
          for_each = {
            APP_ENV            = var.environment
            DB_AUTH            = "gcp-iam"
            DB_INSTANCE        = module.database.connection_name
            DB_NAME            = module.database.database_name
            DB_USER            = module.database.migration_user
            DB_CONNECT_TIMEOUT = "10"
            DB_APP_AUTH        = "gcp-iam"
            DB_APP_ROLE        = module.database.app_user
          }
          content {
            name  = env.key
            value = env.value
          }
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

  lifecycle {
    precondition {
      condition     = length(local.migrate_name) + length(var.migration_token) < 63
      error_message = "The migration job's name and migration_token together must be shorter than 63 characters."
    }
  }
}

resource "google_cloud_run_v2_service" "app" {
  name                = var.service_name
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = var.deletion_protection
  labels              = local.labels

  template {
    # Its own service account, which may only sign in to the database as the service
    service_account = module.database.app_service_account

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    vpc_access {
      egress = "PRIVATE_RANGES_ONLY"
      network_interfaces {
        network    = local.vpc_egress.network
        subnetwork = local.vpc_egress.subnetwork
      }
    }

    containers {
      name  = "multi-cloud-app"
      image = local.image

      ports {
        container_port = 8000
      }

      dynamic "env" {
        for_each = {
          APP_ENV            = var.environment
          APP_VERSION        = var.image_tag
          DB_AUTH            = "gcp-iam"
          DB_INSTANCE        = module.database.connection_name
          DB_NAME            = module.database.database_name
          DB_USER            = module.database.app_user
          DB_CONNECT_TIMEOUT = "10"
        }
        content {
          name  = env.key
          value = env.value
        }
      }

      resources {
        limits = {
          cpu    = "1000m"
          memory = "512Mi"
        }
      }

      # A new instance takes traffic once it can query the database
      startup_probe {
        period_seconds    = 3
        timeout_seconds   = 2
        failure_threshold = 20

        http_get {
          path = "/ready"
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

  # The new revision only rolls out after its migrations succeeded
  depends_on = [google_cloud_run_v2_job.migrate]
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

output "database_instance" {
  value       = module.database.connection_name
  description = "Cloud SQL instance connection name"
}
