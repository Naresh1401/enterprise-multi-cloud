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
  mock_resource "google_service_account" {
    defaults = {
      email  = "mock-sa@example-project.iam.gserviceaccount.com"
      member = "serviceAccount:mock-sa@example-project.iam.gserviceaccount.com"
    }
  }
}

variables {
  project_id  = "example-project"
  environment = "dev"
}

run "dev" {
  command = plan

  assert {
    condition = (
      google_container_cluster.this.enable_autopilot &&
      google_container_cluster.this.release_channel[0].channel == "REGULAR" &&
      google_container_cluster.this.deletion_protection
    )
    error_message = "The cluster must be Autopilot on the REGULAR channel, protected from deletion."
  }
  assert {
    condition = (
      google_container_cluster.this.private_cluster_config[0].enable_private_nodes &&
      !google_container_cluster.this.private_cluster_config[0].enable_private_endpoint
    )
    error_message = "Nodes must have no public IPs; the API endpoint stays reachable for GitHub-hosted runners."
  }
  assert {
    condition = (
      google_compute_subnetwork.this.private_ip_google_access &&
      google_compute_router_nat.this.source_subnetwork_ip_ranges_to_nat == "ALL_SUBNETWORKS_ALL_IP_RANGES"
    )
    error_message = "Private nodes reach Google APIs directly and the internet through Cloud NAT."
  }
  assert {
    condition = (
      google_service_account_iam_member.workload_identity["multi-cloud-app"].member == "serviceAccount:example-project.svc.id.goog[multi-cloud-app/multi-cloud-app]" &&
      google_service_account_iam_member.workload_identity["multi-cloud-app-migrate"].member == "serviceAccount:example-project.svc.id.goog[multi-cloud-app/multi-cloud-app-migrate]" &&
      alltrue([for binding in google_service_account_iam_member.workload_identity : binding.role == "roles/iam.workloadIdentityUser"])
    )
    error_message = "Each Kubernetes service account must act as its own Google service account."
  }
  assert {
    condition     = google_artifact_registry_repository_iam_member.nodes_pull.role == "roles/artifactregistry.reader"
    error_message = "The nodes may only read images."
  }
  assert {
    condition = (
      yamldecode(output.helm_values).database.enabled &&
      can(yamldecode(output.helm_values).serviceAccount.annotations["iam.gke.io/gcp-service-account"]) &&
      can(yamldecode(output.helm_values).database.migrations.serviceAccount.annotations["iam.gke.io/gcp-service-account"]) &&
      length(yamldecode(output.helm_values).database.egress.to) == 1
    )
    error_message = "The chart values must carry both service accounts and the database's private range."
  }
}
