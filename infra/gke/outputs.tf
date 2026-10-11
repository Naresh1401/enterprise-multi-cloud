output "cluster_name" {
  value       = google_container_cluster.this.name
  description = "GKE cluster name"
}

output "location" {
  value       = google_container_cluster.this.location
  description = "Cluster location (region)"
}

output "repository" {
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.app.repository_id}"
  description = "Artifact Registry path the deploy workflow pushes to"
}

output "database_instance" {
  value       = module.database.connection_name
  description = "Cloud SQL instance connection name"
}

output "helm_values" {
  description = "Chart values that connect the release to this cluster's database"
  value = yamlencode({
    serviceAccount = {
      annotations = { "iam.gke.io/gcp-service-account" = module.database.app_service_account }
    }
    database = {
      enabled  = true
      instance = module.database.connection_name
      name     = module.database.database_name
      user     = module.database.app_user
      migrations = {
        user = module.database.migration_user
        serviceAccount = {
          annotations = { "iam.gke.io/gcp-service-account" = module.database.migration_service_account }
        }
      }
      egress = {
        to = [{ ipBlock = { cidr = module.database.private_services_cidr } }]
      }
    }
  })
}
