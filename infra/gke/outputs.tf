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
