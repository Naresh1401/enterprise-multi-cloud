# Plans this folder against a mock Google provider, so `tofu test` works without a GCP project
mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "123456789012"
    }
  }
  mock_resource "google_compute_network" {
    defaults = {
      id        = "projects/example-project/global/networks/mock"
      self_link = "https://www.googleapis.com/compute/v1/projects/example-project/global/networks/mock"
    }
  }
  mock_resource "google_compute_subnetwork" {
    defaults = {
      id        = "projects/example-project/regions/us-central1/subnetworks/mock"
      self_link = "https://www.googleapis.com/compute/v1/projects/example-project/regions/us-central1/subnetworks/mock"
    }
  }
}

# Distinct service accounts, so the assertions can tell the service's from the migration job's
override_resource {
  target = module.database.google_service_account.app
  values = {
    email  = "multi-cloud-app-dev-app@example-project.iam.gserviceaccount.com"
    member = "serviceAccount:multi-cloud-app-dev-app@example-project.iam.gserviceaccount.com"
  }
}
override_resource {
  target = module.database.google_service_account.migration
  values = {
    email  = "multi-cloud-app-dev-migrate@example-project.iam.gserviceaccount.com"
    member = "serviceAccount:multi-cloud-app-dev-migrate@example-project.iam.gserviceaccount.com"
  }
}

variables {
  project_id      = "example-project"
  environment     = "dev"
  service_name    = "multi-cloud-app-dev"
  repository_id   = "multi-cloud-app-dev"
  image_tag       = "0123456789abcdef0123456789abcdef01234567"
  migration_token = "12345678901-1"
}

run "dev" {
  command = plan

  assert {
    condition     = google_cloud_run_v2_service.app.template[0].service_account == "multi-cloud-app-dev-app@example-project.iam.gserviceaccount.com"
    error_message = "Cloud Run must run as the service's own service account."
  }
  assert {
    condition     = google_cloud_run_v2_job.migrate.template[0].template[0].service_account == "multi-cloud-app-dev-migrate@example-project.iam.gserviceaccount.com"
    error_message = "The migration job must run as its own service account."
  }
  assert {
    condition = alltrue([
      for access in [google_cloud_run_v2_service.app.template[0].vpc_access[0], google_cloud_run_v2_job.migrate.template[0].template[0].vpc_access[0]] :
      access.egress == "PRIVATE_RANGES_ONLY" && access.network_interfaces[0].subnetwork == google_compute_subnetwork.run.id
    ])
    error_message = "The service and the job must reach private addresses (the database) through Direct VPC egress."
  }
  assert {
    condition     = google_cloud_run_v2_job.migrate.run_execution_token == "12345678901-1"
    error_message = "A new migration_token must make OpenTofu run the job."
  }
  assert {
    condition     = google_cloud_run_v2_job.migrate.template[0].template[0].containers[0].command == tolist(["python", "-m", "app.migrate"])
    error_message = "The job runs the migrations."
  }
  assert {
    condition = alltrue([
      for pair in ["DB_AUTH=gcp-iam", "DB_USER=multi-cloud-app-dev-app@example-project.iam", "APP_VERSION=0123456789abcdef0123456789abcdef01234567"] :
      contains([for e in google_cloud_run_v2_service.app.template[0].containers[0].env : "${e.name}=${e.value}"], pair)
    ])
    error_message = "The service must sign in as its IAM database user and report the commit."
  }
  assert {
    condition = alltrue([
      for pair in ["DB_USER=multi-cloud-app-dev-migrate@example-project.iam", "DB_APP_ROLE=multi-cloud-app-dev-app@example-project.iam"] :
      contains([for e in google_cloud_run_v2_job.migrate.template[0].template[0].containers[0].env : "${e.name}=${e.value}"], pair)
    ])
    error_message = "The job must sign in as the migration user and grant the service's user."
  }
  assert {
    condition = (
      google_cloud_run_v2_service.app.template[0].containers[0].startup_probe[0].http_get[0].path == "/ready" &&
      google_cloud_run_v2_service.app.template[0].containers[0].liveness_probe[0].http_get[0].path == "/health"
    )
    error_message = "New instances take traffic once /ready passes; /health keeps them alive."
  }
  assert {
    condition = (
      google_cloud_run_v2_service.app.ingress == "INGRESS_TRAFFIC_ALL" &&
      google_cloud_run_v2_service_iam_member.public_access.member == "allUsers"
    )
    error_message = "The demo service is public."
  }
  assert {
    condition     = google_cloud_run_v2_service.app.deletion_protection && google_cloud_run_v2_job.migrate.deletion_protection
    error_message = "The service and the job must be protected from deletion by default."
  }
  assert {
    condition     = google_compute_subnetwork.run.private_ip_google_access && google_compute_subnetwork.run.ip_cidr_range == "10.50.0.0/24"
    error_message = "The egress subnet must be 10.50.0.0/24 with Private Google Access."
  }
  assert {
    condition = (
      length(google_monitoring_alert_policy.error_rate.notification_channels) == 0 &&
      length(google_monitoring_alert_policy.latency.notification_channels) == 0
    )
    error_message = "Without alert_email, the service's alerts must notify no one."
  }
  assert {
    condition     = jsondecode(google_monitoring_dashboard.app.dashboard_json).displayName == "multi-cloud-app-dev"
    error_message = "The dashboard must summarize the service and the database."
  }
}

run "alerts" {
  command = plan

  variables {
    alert_email = "ops@example.com"
  }

  assert {
    condition = (
      google_monitoring_notification_channel.email[0].labels.email_address == "ops@example.com" &&
      contains(google_monitoring_alert_policy.error_rate.notification_channels, google_monitoring_notification_channel.email[0].id)
    )
    error_message = "alert_email must notify the service's alerts through its own channel."
  }
}

run "no_token" {
  command = plan

  variables {
    migration_token = ""
  }

  assert {
    condition     = google_cloud_run_v2_job.migrate.run_execution_token == null
    error_message = "Without a token, applying must not run the job."
  }
}

run "token_too_long" {
  command = plan

  variables {
    migration_token = "0123456789012345678901234567890123456789"
  }

  expect_failures = [google_cloud_run_v2_job.migrate]
}
