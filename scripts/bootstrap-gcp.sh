#!/usr/bin/env bash
set -euo pipefail

echo "GCP bootstrap checklist"
echo "1. Enable Artifact Registry, Cloud Run, and IAM APIs in the project."
echo "2. Create a versioned GCS bucket for Terraform state."
echo "3. Create a deployer service account with Artifact Registry, Cloud Run, and state-bucket permissions."
echo "4. Configure Workload Identity Federation for this GitHub repository and branch."
echo "5. Add GCP_WORKLOAD_IDENTITY_PROVIDER and GCP_SERVICE_ACCOUNT as GitHub Environment secrets."
echo "6. Add GCP_PROJECT_ID, GCP_REGION, GCP_REPOSITORY, GCP_SERVICE_NAME, and GCP_TF_STATE_BUCKET as variables."
echo "7. Run the Deploy to GCP workflow and validate the printed Cloud Run URL."
