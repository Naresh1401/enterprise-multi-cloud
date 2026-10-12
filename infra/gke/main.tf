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
  name = "${var.cluster_name}-${var.environment}"
  labels = merge(var.labels, {
    environment = var.environment
    managed-by  = "opentofu"
  })
}

data "google_project" "this" {}

resource "google_compute_network" "this" {
  name                    = local.name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "this" {
  name                     = local.name
  region                   = var.region
  network                  = google_compute_network.this.id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Private nodes reach the internet (for example public base images) through Cloud NAT
resource "google_compute_router" "this" {
  name    = local.name
  region  = var.region
  network = google_compute_network.this.id
}

resource "google_compute_router_nat" "this" {
  name                               = local.name
  router                             = google_compute_router.this.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

resource "google_artifact_registry_repository" "app" {
  location      = var.region
  repository_id = var.repository_id
  description   = "Container images for the ${local.name} cluster"
  format        = "DOCKER"
  labels        = local.labels
  # Google's own key by default; a customer-managed one only if given one. Set once, at
  # creation: changing it later replaces the repository and its images.
  kms_key_name = local.kms_key_name != "" ? local.kms_key_name : null
}

resource "google_container_cluster" "this" {
  name                = local.name
  location            = var.region
  enable_autopilot    = true
  deletion_protection = var.deletion_protection
  network             = google_compute_network.this.id
  subnetwork          = google_compute_subnetwork.this.id
  resource_labels     = local.labels

  release_channel {
    channel = "REGULAR"
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Nodes get no public IPs. The control plane keeps a public endpoint because GitHub-hosted
  # runners have no fixed address; api_allowed_cidrs narrows who can reach it.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.api_allowed_cidrs
      content {
        cidr_block   = cidr_blocks.value
        display_name = "allowed-${cidr_blocks.key}"
      }
    }
  }
}

# Autopilot nodes run as the Compute Engine default service account; let them pull the images
resource "google_artifact_registry_repository_iam_member" "nodes_pull" {
  location   = google_artifact_registry_repository.app.location
  repository = google_artifact_registry_repository.app.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${data.google_project.this.number}-compute@developer.gserviceaccount.com"
}
