output "connection_name" {
  value       = google_sql_database_instance.this.connection_name
  description = "Instance connection name, project:region:instance, for the Cloud SQL connector"
}

output "database_name" {
  value       = google_sql_database.app.name
  description = "Database the service uses"
}

output "app_service_account" {
  value       = google_service_account.app.email
  description = "Service account the service runs as"
}

output "app_user" {
  value       = google_sql_user.app.name
  description = "PostgreSQL role of the service's service account"
}

output "migration_service_account" {
  value       = google_service_account.migration.email
  description = "Service account the migration job runs as"
}

output "migration_user" {
  value       = google_sql_user.migration.name
  description = "PostgreSQL role of the migration job's service account"
}

output "private_services_cidr" {
  value       = "${google_compute_global_address.private_services.address}/${google_compute_global_address.private_services.prefix_length}"
  description = "Range the instance's private IP comes from"
}
