# PostgreSQL on Cloud SQL for one deployment target (Cloud Run or GKE): a private IP only,
# connections only through the Cloud SQL connectors, and IAM sign-in for both the service and
# the migration job, so no database password exists at all.
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 7.0"
    }
  }
}

locals {
  prod = var.environment == "prod"
  # Service account IDs are 6 to 30 characters
  account_prefix = trimsuffix(substr(var.name, 0, 21), "-")
  # Cloud SQL names PostgreSQL IAM users after the service account, without the domain
  app_user       = trimsuffix(google_service_account.app.email, ".gserviceaccount.com")
  migration_user = trimsuffix(google_service_account.migration.email, ".gserviceaccount.com")
  # Grants on the project apply to this instance only
  instance_condition = "resource.name == 'projects/${var.project_id}/instances/${var.name}' && resource.service == 'sqladmin.googleapis.com'"
}

# Private services access: a range of the VPC that Google peers to the instance's network
resource "google_compute_global_address" "private_services" {
  name          = "${var.name}-private-services"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = var.network_id
}

resource "google_service_networking_connection" "private_services" {
  network                 = var.network_id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_services.name]
  # Deleting the peering fails while Google still tears the instance down; leave it to the network
  deletion_policy = "ABANDON"
}

resource "google_sql_database_instance" "this" {
  name                = var.name
  region              = var.region
  database_version    = var.database_version
  deletion_protection = var.deletion_protection
  # Google's own key by default; a customer-managed one only if given one. Set once, at
  # creation: Cloud SQL can't re-encrypt an existing instance with a different key.
  encryption_key_name = var.kms_key_name != "" ? var.kms_key_name : null

  settings {
    tier                        = var.tier
    edition                     = "ENTERPRISE"
    availability_type           = local.prod ? "REGIONAL" : "ZONAL"
    disk_type                   = "PD_SSD"
    disk_size                   = var.disk_size_gb
    disk_autoresize             = true
    disk_autoresize_limit       = var.disk_autoresize_limit_gb
    deletion_protection_enabled = var.deletion_protection
    # Only the Cloud SQL connectors may connect: each connection is authorized with IAM and
    # encrypted with certificates the connector fetches for the instance
    connector_enforcement = "REQUIRED"
    user_labels           = var.labels

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.network_id
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      start_time                     = "03:00"
      transaction_log_retention_days = 7

      backup_retention_settings {
        retained_backups = local.prod ? 14 : 7
      }
    }

    maintenance_window {
      day          = 7
      hour         = 4
      update_track = "stable"
    }

    insights_config {
      query_insights_enabled = true
    }

    database_flags {
      name  = "cloudsql.iam_authentication"
      value = "on"
    }

    database_flags {
      name  = "log_connections"
      value = "on"
    }

    database_flags {
      name  = "log_disconnections"
      value = "on"
    }

    database_flags {
      name  = "log_checkpoints"
      value = "on"
    }

    database_flags {
      name  = "log_lock_waits"
      value = "on"
    }

    database_flags {
      name  = "log_temp_files"
      value = "0"
    }
  }

  depends_on = [google_service_networking_connection.private_services]
}

resource "google_sql_database" "app" {
  name     = var.database_name
  instance = google_sql_database_instance.this.name
}

# The service's identity: reads and writes rows, nothing more (the migration job grants that)
resource "google_service_account" "app" {
  account_id   = "${local.account_prefix}-app"
  display_name = "${var.name} service"
}

# The migration job's identity: creates and changes the tables
resource "google_service_account" "migration" {
  account_id   = "${local.account_prefix}-migrate"
  display_name = "${var.name} database migrations"
}

resource "google_sql_user" "app" {
  name     = local.app_user
  instance = google_sql_database_instance.this.name
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"
}

resource "google_sql_user" "migration" {
  name           = local.migration_user
  instance       = google_sql_database_instance.this.name
  type           = "CLOUD_IAM_SERVICE_ACCOUNT"
  database_roles = ["cloudsqlsuperuser"]
}

# Connecting through a connector (cloudsql.client) and signing in with IAM (cloudsql.instanceUser)
resource "google_project_iam_member" "database_access" {
  for_each = {
    app-client       = ["roles/cloudsql.client", google_service_account.app.member]
    app-login        = ["roles/cloudsql.instanceUser", google_service_account.app.member]
    migration-client = ["roles/cloudsql.client", google_service_account.migration.member]
    migration-login  = ["roles/cloudsql.instanceUser", google_service_account.migration.member]
  }

  project = var.project_id
  role    = each.value[0]
  member  = each.value[1]

  condition {
    title      = "${var.name}-only"
    expression = local.instance_condition
  }
}
