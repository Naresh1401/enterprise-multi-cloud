# Checks the Cloud SQL settings the architecture relies on, planned against a mock Google
# provider (no GCP project needed): `tofu init -backend=false && tofu test`
mock_provider "google" {}

# Distinct service accounts, so the assertions can tell them apart
override_resource {
  target = google_service_account.app
  values = {
    email  = "multi-cloud-dev-app@example-project.iam.gserviceaccount.com"
    member = "serviceAccount:multi-cloud-dev-app@example-project.iam.gserviceaccount.com"
  }
}
override_resource {
  target = google_service_account.migration
  values = {
    email  = "multi-cloud-dev-migrate@example-project.iam.gserviceaccount.com"
    member = "serviceAccount:multi-cloud-dev-migrate@example-project.iam.gserviceaccount.com"
  }
}

variables {
  name        = "multi-cloud-dev"
  environment = "dev"
  project_id  = "example-project"
  region      = "us-central1"
  network_id  = "projects/example-project/global/networks/multi-cloud-dev"
}

run "dev" {
  command = plan

  assert {
    condition = (
      !google_sql_database_instance.this.settings[0].ip_configuration[0].ipv4_enabled &&
      google_sql_database_instance.this.settings[0].ip_configuration[0].private_network == var.network_id
    )
    error_message = "The instance must have a private IP in the VPC and no public IP."
  }
  assert {
    condition     = google_sql_database_instance.this.settings[0].connector_enforcement == "REQUIRED"
    error_message = "Only the Cloud SQL connectors (IAM-authorized, encrypted) may connect."
  }
  assert {
    condition     = google_sql_database_instance.this.settings[0].ip_configuration[0].ssl_mode == "ENCRYPTED_ONLY"
    error_message = "Unencrypted connections must be refused."
  }
  assert {
    condition     = google_sql_database_instance.this.database_version == "POSTGRES_17" && google_sql_database_instance.this.settings[0].edition == "ENTERPRISE"
    error_message = "The instance must run PostgreSQL 17 on the Enterprise edition."
  }
  assert {
    condition = alltrue([
      for flag in ["cloudsql.iam_authentication=on", "log_connections=on", "log_disconnections=on", "log_checkpoints=on", "log_lock_waits=on", "log_temp_files=0"] :
      contains([for f in google_sql_database_instance.this.settings[0].database_flags : "${f.name}=${f.value}"], flag)
    ])
    error_message = "IAM sign-in and the logging flags must be set."
  }
  assert {
    condition = (
      google_sql_database_instance.this.settings[0].availability_type == "ZONAL" &&
      google_sql_database_instance.this.settings[0].backup_configuration[0].enabled &&
      google_sql_database_instance.this.settings[0].backup_configuration[0].point_in_time_recovery_enabled &&
      google_sql_database_instance.this.settings[0].backup_configuration[0].backup_retention_settings[0].retained_backups == 7
    )
    error_message = "dev runs in one zone with daily backups kept 7 days and point-in-time recovery."
  }
  assert {
    condition     = google_sql_database_instance.this.deletion_protection && google_sql_database_instance.this.settings[0].deletion_protection_enabled
    error_message = "Deletion protection must be on by default, in OpenTofu and in Cloud SQL."
  }
  assert {
    condition     = google_sql_user.app.type == "CLOUD_IAM_SERVICE_ACCOUNT" && google_sql_user.app.name == "multi-cloud-dev-app@example-project.iam"
    error_message = "The service must sign in as its service account, through IAM."
  }
  assert {
    condition     = google_sql_user.app.database_roles == null
    error_message = "The service's database user must get no roles from Cloud SQL; the migration job grants it row access only."
  }
  assert {
    condition = (
      google_sql_user.migration.type == "CLOUD_IAM_SERVICE_ACCOUNT" &&
      google_sql_user.migration.database_roles == tolist(["cloudsqlsuperuser"])
    )
    error_message = "The migration identity must sign in through IAM with cloudsqlsuperuser."
  }
  assert {
    condition = alltrue([
      for m in google_project_iam_member.database_access :
      m.condition[0].expression == "resource.name == 'projects/example-project/instances/multi-cloud-dev' && resource.service == 'sqladmin.googleapis.com'"
    ])
    error_message = "The Cloud SQL roles must apply to this instance only."
  }
  assert {
    condition = (
      toset([for m in google_project_iam_member.database_access : "${m.role} ${m.member}"]) == toset([
        "roles/cloudsql.client serviceAccount:multi-cloud-dev-app@example-project.iam.gserviceaccount.com",
        "roles/cloudsql.instanceUser serviceAccount:multi-cloud-dev-app@example-project.iam.gserviceaccount.com",
        "roles/cloudsql.client serviceAccount:multi-cloud-dev-migrate@example-project.iam.gserviceaccount.com",
        "roles/cloudsql.instanceUser serviceAccount:multi-cloud-dev-migrate@example-project.iam.gserviceaccount.com",
      ])
    )
    error_message = "Each identity gets exactly the client and instance user roles."
  }
  assert {
    condition = (
      google_compute_global_address.private_services.purpose == "VPC_PEERING" &&
      google_compute_global_address.private_services.prefix_length == 20 &&
      google_service_networking_connection.private_services.deletion_policy == "ABANDON"
    )
    error_message = "Private services access must reserve a /20 for the instance's private IP."
  }
}

run "prod" {
  command = plan

  variables {
    name        = "multi-cloud-prod"
    environment = "prod"
  }

  assert {
    condition = (
      google_sql_database_instance.this.settings[0].availability_type == "REGIONAL" &&
      google_sql_database_instance.this.settings[0].backup_configuration[0].backup_retention_settings[0].retained_backups == 14
    )
    error_message = "prod must be regional (high availability) with 14 backups kept."
  }
}
