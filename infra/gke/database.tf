# PostgreSQL for the cluster. The pods sign in with Workload Identity Federation for GKE: each
# Kubernetes service account acts as its own Google service account, which Cloud SQL accepts
# as a database user.
module "database" {
  source = "../modules/gcp-database"

  name                = local.name
  environment         = var.environment
  project_id          = var.project_id
  region              = var.region
  network_id          = google_compute_network.this.id
  tier                = var.database_tier
  deletion_protection = var.deletion_protection
  labels              = local.labels
}

resource "google_service_account_iam_member" "workload_identity" {
  for_each = {
    (var.release_name)            = module.database.app_service_account
    "${var.release_name}-migrate" = module.database.migration_service_account
  }

  service_account_id = "projects/${var.project_id}/serviceAccounts/${each.value}"
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.kubernetes_namespace}/${each.key}]"

  # The workload identity pool only exists once the cluster does
  depends_on = [google_container_cluster.this]
}
