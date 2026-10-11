#!/usr/bin/env bash
# Prints the one-time GCP setup. docs/gcp-deployment.md has the exact commands.
set -euo pipefail

cat <<'STEPS'
GCP bootstrap (one time, see docs/gcp-deployment.md)

1. Enable the Cloud Run, Artifact Registry, IAM, IAM Credentials, STS and
   Cloud Resource Manager APIs.
2. Create a versioned GCS bucket for OpenTofu state with uniform access and
   public access prevention.
3. Create a deployer service account with Cloud Run Admin, Artifact Registry
   Admin and Service Account User, plus Storage Object Admin on the state bucket.
4. Create a Workload Identity pool and GitHub OIDC provider limited to this
   repository, and let the repository impersonate the deployer.
5. Add GCP_WORKLOAD_IDENTITY_PROVIDER and GCP_SERVICE_ACCOUNT as secrets, and
   GCP_PROJECT_ID, GCP_REGION, GCP_REPOSITORY, GCP_SERVICE_NAME and
   GCP_TF_STATE_BUCKET as variables, in each GitHub Environment.
6. Run "Deploy to GCP" and confirm the run summary shows the commit SHA.

No service account key is needed. Do not create the Artifact Registry
repository or Cloud Run service by hand; OpenTofu creates them.
STEPS
