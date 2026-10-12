# One customer-managed Cloud KMS key for this target's image repository and database. Off by
# default (enable_customer_managed_key): Google's own keys encrypt both already.
#
# Enabling it after the repository or the instance already exist forces OpenTofu to replace
# them: neither Artifact Registry nor Cloud SQL can re-encrypt existing data with a different
# key. Set it before the first apply, not after.
resource "google_kms_key_ring" "this" {
  count = var.enable_customer_managed_key ? 1 : 0

  name     = var.service_name
  location = var.region
}

resource "google_kms_crypto_key" "this" {
  count = var.enable_customer_managed_key ? 1 : 0

  name            = "database-and-registry"
  key_ring        = google_kms_key_ring.this[0].id
  rotation_period = "7776000s" # 90 days

  lifecycle {
    prevent_destroy = true
  }
}

# Cloud SQL and Artifact Registry each encrypt with the key through their own Google-managed
# service agent, not the identity running OpenTofu. Service agent emails follow Google's
# documented, stable format; project_number comes from data.google_project.this.
data "google_project" "this" {}

resource "google_kms_crypto_key_iam_member" "cloudsql" {
  count = var.enable_customer_managed_key ? 1 : 0

  crypto_key_id = google_kms_crypto_key.this[0].id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-cloud-sql.iam.gserviceaccount.com"
}

resource "google_kms_crypto_key_iam_member" "artifactregistry" {
  count = var.enable_customer_managed_key ? 1 : 0

  crypto_key_id = google_kms_crypto_key.this[0].id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-artifactregistry.iam.gserviceaccount.com"
}

locals {
  kms_key_name = var.enable_customer_managed_key ? google_kms_crypto_key.this[0].id : ""
}
